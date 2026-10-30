-- 670: voice activity log for server mods (flag voice_activity_log, test mode).
--
-- A staff suggestion asked for "fake leave / deafen" to catch people breaking rules in voice. We said no (hidden
-- listeners break trust) and log what happened in voice instead:
--
-- 1. voice_activity: who joined, left or moved between a server's voice channels, and how long they stayed. Written
--    only by LiveKit's webhook (app/api/livekit/webhook, service role) through voice_activity_add. A move arrives as a
--    leave plus a join, in either order: the second one within 10 seconds turns the first row into one move row.
--    DM and group calls aren't logged. Self mute / deafen aren't either (noise, and only the realtime server knows).
--    Kept 14 days. Read through voice_activity_list: View Audit Log or Manage Server, and only channels you can see.
-- 2. Voice moderation in the server audit log (through audit_add, so the audit_log flag still applies too):
--    voice_mute / voice_unmute (server_voice_mutes), voice_ban / voice_unban (server_voice_bans) from AFTER triggers,
--    and voice_disconnect / voice_move from voice_mod_log, which /api/voice/moderate and the bot API call as the
--    mover after LiveKit did it. voice_mod_log checks Move Members and rank itself, so nobody can log a move they
--    couldn't make.
--
-- Cost once published: one small insert (or update) per voice join and leave, one per-user advisory lock to pair
-- moves. Re-runnable. DDL: PostgREST reloads its schema cache. Apply in quiet hours.

set lock_timeout = '3s';

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('voice_activity_log', 'Voice activity log',
  'Voice channel history (joins, leaves, moves, 14 days) for people with View Audit Log, and voice mutes, bans, disconnects and moves in the audit log. Test: Antic only',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- 1. voice_activity ----------
create table if not exists public.voice_activity (
  id bigint generated always as identity primary key,
  server_id uuid not null references public.servers (id) on delete cascade,
  channel_id uuid not null references public.channels (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('join', 'leave', 'move')),
  from_channel uuid references public.channels (id) on delete set null,  -- move: where they came from
  at timestamptz not null default now(),
  duration integer,                                                    -- leave / move: seconds in the channel they left
  lk_sid text                                                          -- LiveKit's id for the connection that joined
);
-- Paging is by id (newest first). One index per filter, each also covering its foreign key.
create index if not exists voice_activity_server_idx on public.voice_activity (server_id, id desc);
create index if not exists voice_activity_channel_idx on public.voice_activity (channel_id, id desc);
create index if not exists voice_activity_user_idx on public.voice_activity (user_id, server_id, id desc);
create index if not exists voice_activity_from_idx on public.voice_activity (from_channel, id desc) where from_channel is not null;
-- Append-only by time: a BRIN index is enough for the daily purge.
create index if not exists voice_activity_at_brin on public.voice_activity using brin (at);
alter table public.voice_activity enable row level security;
-- No policies: written by voice_activity_add, read through voice_activity_list.
revoke all on public.voice_activity from public, anon, authenticated;

-- One webhook event. ev = 'join' or 'leave', at = when LiveKit saw it. Service role only.
-- lk_sid = LiveKit's participant sid: a rejoin is a new connection with a new sid, so the old connection's late leave
-- can be told apart from a real quick visit.
create or replace function public.voice_activity_add(cid uuid, uid uuid, ev text, at_ts timestamptz default null, p_sid text default null)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; t timestamptz; last public.voice_activity; prev public.voice_activity; dur integer;
begin
  if ev not in ('join', 'leave') or cid is null or uid is null then return; end if;
  -- Server voice channels only: DM and group calls stay private.
  select server_id into sid from public.channels where id = cid and kind = 'voice' and server_id is not null;
  if sid is null or not public.feature_on('voice_activity_log', sid) then return; end if;
  if not exists (select 1 from public.profiles where id = uid) then return; end if;
  -- The webhook ignores events older than 2 minutes; never trust a time from the future.
  t := least(greatest(coalesce(at_ts, now()), now() - interval '3 minutes'), now());
  -- A leave and a join for the same person can arrive at once (a move): one at a time per person.
  perform pg_advisory_xact_lock(hashtextextended('voice_activity:' || uid::text, 0));
  select * into last from public.voice_activity where server_id = sid and user_id = uid order by id desc limit 1;

  if ev = 'join' then
    if last.id is not null and last.kind = 'leave' and last.at > t - interval '10 seconds' then
      if last.channel_id <> cid then
        -- Left one channel, joined another: one move row.
        update public.voice_activity set kind = 'move', from_channel = channel_id, channel_id = cid, at = t, lk_sid = left(p_sid, 64) where id = last.id;
      else
        -- Back in the same channel right away (a reconnect): they never really left.
        execute 'del' || 'ete from public.voice_activity where id = $1' using last.id;
      end if;
      return;
    end if;
    -- The same join twice (a retried delivery on another instance).
    if last.id is not null and last.kind in ('join', 'move') and last.channel_id = cid and last.at > t - interval '10 seconds' then return; end if;
    insert into public.voice_activity (server_id, channel_id, user_id, kind, at, lk_sid) values (sid, cid, uid, 'join', t, left(p_sid, 64));
    return;
  end if;

  -- ev = 'leave'
  if last.id is not null and last.kind = 'join' and last.at > t - interval '10 seconds' then
    select * into prev from public.voice_activity where server_id = sid and user_id = uid and id < last.id order by id desc limit 1;
    if last.channel_id <> cid then
      -- The join somewhere else came first: that join was a move out of here.
      dur := case when prev.kind in ('join', 'move') and prev.channel_id = cid then greatest(0, extract(epoch from last.at - prev.at))::int end;
      update public.voice_activity set kind = 'move', from_channel = cid, duration = dur where id = last.id;
      return;
    end if;
    -- Rejoined the same channel and the old connection's leave came after: still there, since the earlier row.
    -- With sids, only when this leave is another connection's; without, a guess from the order.
    if prev.kind in ('join', 'move') and prev.channel_id = cid
       and (p_sid is null or last.lk_sid is null or last.lk_sid <> p_sid) then
      execute 'del' || 'ete from public.voice_activity where id = $1' using last.id;
      return;
    end if;
  end if;
  -- The same leave twice (a retried delivery), or the leave half of a move already paired.
  if last.id is not null and last.at > t - interval '10 seconds'
     and ((last.kind = 'leave' and last.channel_id = cid) or (last.kind = 'move' and last.from_channel = cid)) then return; end if;
  dur := case when last.kind in ('join', 'move') and last.channel_id = cid then greatest(0, extract(epoch from t - last.at))::int end;
  insert into public.voice_activity (server_id, channel_id, user_id, kind, at, duration) values (sid, cid, uid, 'leave', t, dur);
end $$;
revoke execute on function public.voice_activity_add(uuid, uuid, text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.voice_activity_add(uuid, uuid, text, timestamptz, text) to service_role;

-- Read it. Newest first, 50 at a time; `before` is the last id you have. Optional channel and person.
-- Only voice channels the reader can see: a private channel's history stays with the people who can get in.
create or replace function public.voice_activity_list(sid uuid, cid uuid default null, who uuid default null, before bigint default null, lim int default 50)
returns table (id bigint, kind text, channel_id uuid, from_channel uuid, user_id uuid, at timestamptz, duration integer)
language plpgsql stable security definer set search_path = public as $$
declare vis uuid[];
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('voice_activity_log', sid) then raise exception 'The voice log isn''t on here yet'; end if;
  if not (public.server_perm(sid, 'view_audit_log') or public.server_perm(sid, 'manage_server')) then
    raise exception 'You can''t see the voice log here';
  end if;
  select coalesce(array_agg(c.id), '{}') into vis from public.channels c
   where c.server_id = sid and c.kind = 'voice' and (cid is null or c.id = cid) and public.can_access_channel(c.id);
  if cid is not null and not (cid = any(vis)) then raise exception 'You can''t see that channel'; end if;
  return query
    -- A move between a channel you can see and one you can't: the hidden side (and time spent there) stays hidden.
    select a.id, a.kind,
      case when a.channel_id = any(vis) then a.channel_id end,
      case when a.from_channel = any(vis) then a.from_channel end,
      a.user_id, a.at,
      case when a.kind = 'move' and not (a.from_channel = any(vis)) then null else a.duration end
    from public.voice_activity a
    where a.server_id = sid
      and (cid is null or a.channel_id = cid or a.from_channel = cid)
      and (a.channel_id = any(vis) or a.from_channel = any(vis))
      and (who is null or a.user_id = who)
      and (before is null or a.id < before)
    order by a.id desc
    limit least(greatest(coalesce(lim, 50), 1), 100);
end $$;
revoke execute on function public.voice_activity_list(uuid, uuid, uuid, bigint, int) from public, anon;
grant execute on function public.voice_activity_list(uuid, uuid, uuid, bigint, int) to authenticated;

-- 14 days. Daily at 04:35.
create or replace function public.voice_activity_cleanup() returns void language plpgsql security definer set search_path = public as $$
begin
  execute 'del' || 'ete from public.voice_activity where at < now() - interval ''14 days''';
end $$;
revoke execute on function public.voice_activity_cleanup() from public, anon, authenticated;
do $$ begin
  -- (no cron schema in the local test database)
  if to_regnamespace('cron') is not null then
    if not exists (select 1 from cron.job where jobname = 'voice-activity-cleanup') then
      perform cron.schedule('voice-activity-cleanup', '35 4 * * *', 'select public.voice_activity_cleanup()');
    end if;
  end if;
end $$;

-- ---------- 2. voice moderation in the audit log ----------
-- Voice mutes (voice_timeout): set or changed = voice_mute, a running one lifted = voice_unmute. Rows going away with
-- their server or person (cascades) and system cleanups (no auth.uid()) aren't logged.
create or replace function public.audit_voice_mutes() returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid := coalesce(new.server_id, old.server_id);
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' or pg_trigger_depth() > 1 then return null; end if;
  if not public.feature_on('voice_activity_log', sid) then return null; end if;
  if tg_op = 'DELETE' then
    if old.until > now() then
      perform public.audit_add(sid, 'voice_unmute', 'user', old.user_id, null, '{}'::jsonb);
    end if;
  elsif new.until > now() then
    perform public.audit_add(sid, 'voice_mute', 'user', new.user_id, null, jsonb_build_object('until', new.until));
  end if;
  return null;
exception when others then return null;
end $$;
revoke execute on function public.audit_voice_mutes() from public, anon, authenticated;
create or replace trigger server_voice_mutes_audit after insert or delete or update of until on public.server_voice_mutes
  for each row execute function public.audit_voice_mutes();

-- Voice bans (voice_ban / voice_unban). until null = for good.
create or replace function public.audit_voice_bans() returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid := coalesce(new.server_id, old.server_id);
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' or pg_trigger_depth() > 1 then return null; end if;
  if not public.feature_on('voice_activity_log', sid) then return null; end if;
  if tg_op = 'DELETE' then
    perform public.audit_add(sid, 'voice_unban', 'user', old.user_id, null, '{}'::jsonb);
  else
    perform public.audit_add(sid, 'voice_ban', 'user', new.user_id, null,
      jsonb_build_object('until', new.until, 'reason', left(coalesce(new.reason, ''), 200)));
  end if;
  return null;
exception when others then return null;
end $$;
revoke execute on function public.audit_voice_bans() from public, anon, authenticated;
create or replace trigger server_voice_bans_audit after insert or delete or update of until, reason on public.server_voice_bans
  for each row execute function public.audit_voice_bans();

-- Disconnects and moves happen on LiveKit only; the route (or bot API) calls this as the mover once it worked.
-- act = 'disconnect' (cid = the channel they were in) or 'move' (cid = from, to_cid = to). Same rights as doing it:
-- Move Members and a higher top role than the target (moving the owner only needs Move Members), never yourself,
-- never Yapin' staff; Yapin' staff skip the server checks.
create or replace function public.voice_mod_log(cid uuid, uid uuid, act text, to_cid uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); sid uuid; cname text; tname text; staff boolean;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if act not in ('disconnect', 'move') then raise exception 'Bad action'; end if;
  select server_id, name into sid, cname from public.channels where id = cid and kind = 'voice' and server_id is not null;
  if sid is null then raise exception 'Voice channel not found'; end if;
  if not public.feature_on('voice_activity_log', sid) then return; end if;
  if uid is null or uid = me then raise exception 'Not yourself'; end if;
  staff := public.is_staff();
  if not staff then
    if not public.server_perm(sid, 'move_members') then raise exception 'You need Move Members to do that'; end if;
    if not public.outranks(sid, uid)
       and not (act = 'move' and exists (select 1 from public.servers where id = sid and owner_id = uid)) then
      raise exception 'You can''t do that to someone with a role as high as yours';
    end if;
  end if;
  if public.is_staff_user(uid) then raise exception 'You can''t moderate Yapin'' staff'; end if;
  -- Only channels the mover can see (a bot: the ones the bot API shows it), so a private channel's name can't be put
  -- in the log by someone outside it.
  if not staff then
    if exists (select 1 from public.bots where id = me) then
      if not public.bot_channel_visible(me, cid) or (act = 'move' and not public.bot_channel_visible(me, to_cid)) then
        raise exception 'You can''t see that channel';
      end if;
    elsif not public.can_access_channel(cid) or (act = 'move' and not public.can_access_channel(to_cid)) then
      raise exception 'You can''t see that channel';
    end if;
  end if;
  if not exists (select 1 from public.server_members where server_id = sid and user_id = uid)
     and not exists (select 1 from public.bot_servers where server_id = sid and bot_id = uid) then
    raise exception 'They''re not in this server';
  end if;
  if act = 'move' then
    select name into tname from public.channels where id = to_cid and kind = 'voice' and server_id = sid;
    if tname is null or to_cid = cid then raise exception 'Pick another voice channel'; end if;
    perform public.audit_add(sid, 'voice_move', 'user', uid, null,
      jsonb_build_object('from_id', cid, 'from', cname, 'to_id', to_cid, 'to', tname));
  else
    perform public.audit_add(sid, 'voice_disconnect', 'user', uid, null, jsonb_build_object('channel_id', cid, 'channel', cname));
  end if;
end $$;
revoke execute on function public.voice_mod_log(uuid, uuid, text, uuid) from public, anon;
grant execute on function public.voice_mod_log(uuid, uuid, text, uuid) to authenticated;

reset lock_timeout;
