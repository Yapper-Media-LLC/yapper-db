-- 184: bot voice (flag bot_voice, test mode). Bots can list who is in voice, move people between voice channels,
-- disconnect them, and get voice_join / voice_leave events, so people can build join-to-create bots.
--
-- Who is in voice lives in LiveKit (room name = channel id), not in the database, so the API route reads it from
-- LiveKit and LiveKit tells us about joins and leaves through its webhook (app/api/livekit/webhook/route.ts).
-- The database part is small:
--   * bot_voice_gate(bid, sid, act): one call before every bot voice endpoint. Says why not (or null when fine):
--     the bot isn't in that server, the flag is off for that server, or the bot is over its limit: 30 moves and
--     disconnects a minute (act = true), 60 lookups a minute (act = false; each GET /voice can cost up to 51
--     LiveKit calls). Separate buckets, so looking doesn't use up moves. feature_on(k, sid) runs with no auth.uid() here (service role),
--     so in test mode only the servers listed on the flag count, which is what we want.
--   * bot_voice_event(cid, uid, ev): the webhook's one round trip. Looks up the channel's server, does nothing
--     for DMs, non-voice channels or servers where the flag is off, then queues the event (bot_push) for every bot
--     in that server that can see the channel and isn't the person themselves. Returns how many bots got it.
--   * bot_voice_rate: one row per bot (fixed one-minute windows, one for actions and one for lookups, updated in
--     place, never grows).
-- All three are service role only: anon and authenticated can't call or read them.

create table if not exists public.bot_voice_rate (
  bot_id uuid primary key references public.bots (id) on delete cascade,
  window_start timestamptz not null default now(),
  n int not null default 0
);
alter table public.bot_voice_rate add column if not exists read_window_start timestamptz not null default now();
alter table public.bot_voice_rate add column if not exists read_n int not null default 0;
alter table public.bot_voice_rate enable row level security;
revoke all on table public.bot_voice_rate from public, anon, authenticated;

create or replace function public.bot_voice_gate(bid uuid, sid uuid, act boolean default false)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if bid is null or sid is null then return 'Bad request'; end if;
  if not exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = sid) then
    return 'The bot is not in that server';
  end if;
  if not public.feature_on('bot_voice', sid) then
    return 'Bot voice isn''t on in this server yet';
  end if;
  if act then
    insert into public.bot_voice_rate as r (bot_id, window_start, n) values (bid, now(), 1)
    on conflict (bot_id) do update
      set window_start = case when r.window_start < now() - interval '1 minute' then now() else r.window_start end,
          n = case when r.window_start < now() - interval '1 minute' then 1 else r.n + 1 end
    returning r.n into n;
    if n > 30 then return 'Slow down: 30 voice moves a minute per bot'; end if;
  else
    insert into public.bot_voice_rate as r (bot_id, read_window_start, read_n) values (bid, now(), 1)
    on conflict (bot_id) do update
      set read_window_start = case when r.read_window_start < now() - interval '1 minute' then now() else r.read_window_start end,
          read_n = case when r.read_window_start < now() - interval '1 minute' then 1 else r.read_n + 1 end
    returning r.read_n into n;
    if n > 60 then return 'Slow down: 60 voice lookups a minute per bot'; end if;
  end if;
  return null;
end $$;

create or replace function public.bot_voice_event(cid uuid, uid uuid, ev text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; k text; b record; sent int := 0;
begin
  if ev not in ('voice_join', 'voice_leave') then raise exception 'Unknown voice event %', ev; end if;
  if cid is null or uid is null then return 0; end if;
  select c.server_id, c.kind into sid, k from public.channels c where c.id = cid;
  if sid is null or k is distinct from 'voice' then return 0; end if;
  if not public.feature_on('bot_voice', sid) then return 0; end if;
  for b in select bo.id, bo.webhook_url, bo.webhook_secret
             from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id
            where bs.server_id = sid and bo.id <> uid loop
    if not public.bot_channel_visible(b.id, cid) then continue; end if;
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, ev,
      jsonb_build_object('user_id', uid, 'channel_id', cid, 'server_id', sid));
    sent := sent + 1;
  end loop;
  return sent;
end $$;

revoke all on function public.bot_voice_gate(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.bot_voice_event(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.bot_voice_gate(uuid, uuid, boolean) to service_role;
grant execute on function public.bot_voice_event(uuid, uuid, text) to service_role;

insert into public.feature_flags (key, label, description, mode, servers)
values ('bot_voice', 'Bot voice', 'Bots can see who is in voice, move people and get voice join/leave events', 'test', '{}')
on conflict (key) do nothing;
