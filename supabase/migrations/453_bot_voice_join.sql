-- 453: bots join voice and play audio (flag bot_voice_join, test mode: HQ test server). Music bots.
--
-- A bot asks the bot API for a LiveKit ticket (POST /servers/:id/voice/join) and runs the audio side itself
-- (@livekit/rtc-node or the livekit Python SDK). The route checks everything with voice_ticket_for(bot, channel),
-- the same checks people get (sees the channel, Connect, Speak, server ban, voice ban, timeouts, site ban). The
-- database part here:
--   * bot_voice_join_gate(bid, sid, leaving): before every join and leave. Says why not (or null when fine): the bot
--     isn't in that server, the flag is off for that server, or it is over 10 joins and leaves a minute. A leave only
--     counts toward the limit: a bot kicked from the server, or with the flag turned off, can still hang up. Own bucket
--     in bot_voice_rate (two new columns), so moving people around doesn't use it up.
--   * bot_voice_event (from 184, the LiveKit webhook's one call), two changes:
--       - a bot now gets voice_join / voice_leave about itself where bot_voice_join is on (a mod kicked it, it
--         dropped). Other bots still hear it as before.
--       - when the participant is a bot it tells the realtime server (public.bc -> /publish, event bot_voice on
--         server:<id>), which lists it in that server's voice snapshot. People report their own voice presence from
--         the app; bots don't run the app, so without this nobody outside the call would see the bot there.
--         Leaves are always sent (clearing is harmless), joins only where bot_voice_join is on.
-- Both functions are service role only.

alter table public.bot_voice_rate add column if not exists join_window_start timestamptz not null default now();
alter table public.bot_voice_rate add column if not exists join_n int not null default 0;

create or replace function public.bot_voice_join_gate(bid uuid, sid uuid, leaving boolean default false)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if bid is null or sid is null then return 'Bad request'; end if;
  if not coalesce(leaving, false) then
    if not exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = sid) then
      return 'The bot is not in that server';
    end if;
    if not public.feature_on('bot_voice_join', sid) then
      return 'Bots can''t join voice in this server yet';
    end if;
  end if;
  insert into public.bot_voice_rate as r (bot_id, join_window_start, join_n) values (bid, now(), 1)
  on conflict (bot_id) do update
    set join_window_start = case when r.join_window_start < now() - interval '1 minute' then now() else r.join_window_start end,
        join_n = case when r.join_window_start < now() - interval '1 minute' then 1 else r.join_n + 1 end
  returning r.join_n into n;
  if n > 10 then return 'Slow down: 10 voice joins and leaves a minute per bot'; end if;
  return null;
end $$;

create or replace function public.bot_voice_event(cid uuid, uid uuid, ev text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; k text; b record; sent int := 0; joins boolean; pres record;
begin
  if ev not in ('voice_join', 'voice_leave') then raise exception 'Unknown voice event %', ev; end if;
  if cid is null or uid is null then return 0; end if;
  select c.server_id, c.kind into sid, k from public.channels c where c.id = cid;
  if sid is null or k is distinct from 'voice' then return 0; end if;
  joins := public.feature_on('bot_voice_join', sid);
  -- 453: a bot in a call shows in the server's voice list (ops/realtime/server.mjs, event bot_voice).
  if exists (select 1 from public.bots bo where bo.id = uid) and (ev = 'voice_leave' or joins) then
    select uid as user_id, sid as server_id, cid as channel_id, ev = 'voice_join' as joined into pres;
    perform public.bc('server:' || sid, 'bot_voice', 'UPDATE', 'bot_voice', 'public', pres, null);
  end if;
  if not public.feature_on('bot_voice', sid) then return 0; end if;
  for b in select bo.id, bo.webhook_url, bo.webhook_secret
             from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id
            where bs.server_id = sid and (bo.id <> uid or joins) loop
    if not public.bot_channel_visible(b.id, cid) then continue; end if;
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, ev,
      jsonb_build_object('user_id', uid, 'channel_id', cid, 'server_id', sid));
    sent := sent + 1;
  end loop;
  return sent;
end $$;

revoke all on function public.bot_voice_join_gate(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.bot_voice_event(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.bot_voice_join_gate(uuid, uuid, boolean) to service_role;
grant execute on function public.bot_voice_event(uuid, uuid, text) to service_role;

insert into public.feature_flags (key, label, description, mode, servers)
values ('bot_voice_join', 'Bots in voice', 'Bots can join voice channels and play audio (music bots)', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[])
on conflict (key) do nothing;
