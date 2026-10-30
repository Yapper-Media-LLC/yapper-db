-- 628: the online window follows the slower heartbeat (Antic, Oct 28: "fix online counts not showing correctly").
--
-- Flag rt_presence is on for everyone since Oct 27, so a tab tells the realtime server its status and only writes a
-- database heartbeat every 5 minutes (lib/presence.ts RT_DB_EVERY). Every database "online" test still looked for a
-- heartbeat in the last 100 seconds, which fit the old 45 s beat: so at any moment most people had their last beat
-- more than 100 s ago and counted as offline. The homepage said "339 people online now" with ~1,100 actually online;
-- the invite card's online count, Find people's "online" filter and @here's targets had the same hole, and the
-- heartbeat reset online_since on nearly every beat (so "online for" restarted every 5 minutes and who_online sent
-- everyone as "changed" on every poll).
--
-- One window now, presence_ttl() = 7 minutes: a 5 minute beat plus the 45 s tick it waits for, plus a throttled
-- background tab. Used by online_count (137), invite_card (378), search_people (141/480), here_targets (562, patched
-- only where it exists), who_online and heartbeat (263) and bot_presence (121). Going invisible or closing the tab
-- still drops you at once: the heartbeat sets last_seen back by the window. online_time counts the real gap between
-- beats (was capped at 60 s, so a 5 minute beat counted one minute in five).
--
-- Re-runnable: create or replace, and the text patches skip when there is nothing left to patch. DDL, so PostgREST
-- reloads its schema: quiet hours.

create or replace function public.presence_ttl()
returns interval
language sql
immutable
parallel safe
as $$ select interval '7 minutes' $$;
revoke all on function public.presence_ttl() from public;
grant execute on function public.presence_ttl() to anon, authenticated, service_role;

-- 137: the homepage counter.
create or replace function public.online_count()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from public.presence p
  where p.last_seen > now() - public.presence_ttl()
    and not exists (select 1 from public.bot_accounts b where b.user_id = p.user_id)
    and not exists (select 1 from public.bots d where d.id = p.user_id);
$$;
revoke all on function public.online_count() from public;
grant execute on function public.online_count() to anon, authenticated;

-- 378: the invite card.
create or replace function public.invite_card(invite_code text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'server_id', s.id, 'name', s.name, 'icon_path', s.icon_path,
    'banner_path', s.banner_path, 'banner_x', s.banner_x, 'banner_y', s.banner_y, 'banner_zoom', s.banner_zoom,
    'created_at', s.created_at,
    'member_count', (select count(*) from public.server_members m where m.server_id = s.id),
    'online_count', (select count(*) from public.server_members m join public.presence p on p.user_id = m.user_id
                     where m.server_id = s.id and p.last_seen > now() - public.presence_ttl()),
    'already_member', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid())
  )
  from public.invites i join public.servers s on s.id = i.server_id
  where lower(i.code) = lower(invite_code);
$function$;
revoke all on function public.invite_card(text) from public;
grant execute on function public.invite_card(text) to anon, authenticated, service_role;

-- 263: the heartbeat. Same as live except the window and the online_time cap.
create or replace function public.heartbeat(st text, act jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); prev timestamptz; gap int; a jsonb; pf text; ttl interval := public.presence_ttl();
begin
  if me is null then return; end if;
  -- The account's chosen status wins over whatever an older tab sends.
  select pref into pf from public.presence where user_id = me;
  if pf = 'invisible' and st is distinct from 'off' then st := 'invisible'; end if;
  if pf = 'dnd' and st in ('online', 'idle') then st := 'dnd'; end if;
  if pf = 'idle' and st = 'online' then st := 'idle'; end if;
  if st is null or st = 'invisible' or st = 'off' then
    update public.presence set last_seen = now() - ttl where user_id = me and last_seen > now() - ttl;
    return;
  end if;
  if st not in ('online', 'idle', 'dnd') then st := 'online'; end if;
  if act is not null and jsonb_typeof(act) = 'object' and coalesce(act->>'name', '') <> '' then
    a := jsonb_build_object('name', left(act->>'name', 60), 'since', coalesce(act->>'since', now()::text));
  end if;
  select last_seen into prev from public.presence where user_id = me;
  if prev is not null and prev > now() - ttl then
    -- Time online since the last beat; a beat can be up to the window apart now, so count all of it.
    gap := least(extract(epoch from ttl)::int, greatest(0, extract(epoch from (now() - prev))::int));
    insert into public.online_time (user_id, day, secs) values (me, current_date, gap)
      on conflict (user_id, day) do update set secs = online_time.secs + excluded.secs;
  end if;
  insert into public.presence (user_id, status, activity, activity_at) values (me, st, a, case when a is null then null else now() end)
  on conflict (user_id) do update set
    last_seen = now(),
    online_since = case when presence.last_seen < now() - ttl then now() else presence.online_since end,
    status = excluded.status,
    status_at = case when presence.status is distinct from excluded.status then now() else presence.status_at end,
    activity = case when (presence.activity->>'name') is distinct from (excluded.activity->>'name') then excluded.activity else presence.activity end,
    activity_at = case when (presence.activity->>'name') is distinct from (excluded.activity->>'name') then now() else presence.activity_at end;
end $$;
revoke all on function public.heartbeat(text, jsonb) from public, anon;
grant execute on function public.heartbeat(text, jsonb) to authenticated;

-- 263: who is online / what changed. Same as live except the window.
create or replace function public.who_online(sid uuid, extra uuid[], since timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  ttl interval := public.presence_ttl();
  ids uuid[] := (coalesce(extra, '{}'::uuid[]))[1:500];
  -- Never later than now (a client clock can't push the window forward), never more than 15 minutes back (was 10:
  -- a poll in rt_presence mode is already 6 to 7.5 min after the last one, and a late one past the clamp would miss
  -- people who expired in between, so they stayed green until a full look).
  since_ timestamptz := case when since is null then null else greatest(least(since, now()), now() - interval '15 minutes') end;
  rows jsonb;
begin
  if me is null then return '{}'::jsonb; end if;
  if sid is not null and not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then sid := null; end if;
  select coalesce(jsonb_agg(jsonb_build_array(p.user_id, case when p.last_seen > now() - ttl then p.status else 'off' end, p.activity)), '[]'::jsonb)
    into rows
  from public.presence p
  where p.last_seen > coalesce(since_, now()) - ttl
    and (p.user_id = any(ids) or (sid is not null and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.user_id)))
    and (
      (since_ is null and p.last_seen > now() - ttl)
      or (since_ is not null and (p.online_since > since_ or p.status_at > since_ or p.activity_at > since_ or (p.last_seen <= now() - ttl and p.last_seen > since_ - ttl)))
    );
  return jsonb_build_object('now', now(), 'rows', rows);
end; $$;
revoke all on function public.who_online(uuid, uuid[], timestamptz) from public, anon;
grant execute on function public.who_online(uuid, uuid[], timestamptz) to authenticated;

-- 121: a bot's beat. Same as live except the window for online_since.
create or replace function public.bot_presence(bid uuid, st text default null, act jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare saved jsonb; s text; a jsonb;
begin
  if st is null then
    select presence into saved from public.bots where id = bid;
    s := coalesce(saved ->> 'st', 'online');
    a := saved -> 'act';
  else
    s := st; a := act;
  end if;
  if s not in ('online', 'idle', 'dnd') then s := 'online'; end if;
  if a is not null and (jsonb_typeof(a) <> 'object' or coalesce(a ->> 'name', '') = '') then a := null; end if;
  insert into public.presence (user_id, status, activity, activity_at) values (bid, s, a, case when a is null then null else now() end)
  on conflict (user_id) do update set
    last_seen = now(),
    online_since = case when presence.last_seen < now() - public.presence_ttl() then now() else presence.online_since end,
    status = s,
    status_at = case when presence.status is distinct from s then now() else presence.status_at end,
    activity = case when (presence.activity ->> 'name') is distinct from (a ->> 'name') then a else presence.activity end,
    activity_at = case when (presence.activity ->> 'name') is distinct from (a ->> 'name') then now() else presence.activity_at end;
end $$;
revoke all on function public.bot_presence(uuid, text, jsonb) from public, anon, authenticated;

-- search_people (141, patched live by 480) and here_targets (562, only where it has been applied): swap the window in
-- their live text, like 480 did, so nothing else about them changes. Skipped once there is nothing left to swap.
do $$
declare f regprocedure; d text; n int;
begin
  foreach f in array array['public.search_people(text)'::regprocedure] loop
    d := pg_get_functiondef(f);
    n := (length(d) - length(replace(d, 'interval ''100 seconds''', ''))) / length('interval ''100 seconds''');
    if n = 0 then continue; end if;
    if n <> 2 then raise exception '% changed: expected the window twice, found %. Read its live text again', f, n; end if;
    execute replace(d, 'interval ''100 seconds''', 'public.presence_ttl()');
  end loop;
  if to_regprocedure('public.here_targets(uuid, uuid, uuid, boolean)') is not null then
    d := pg_get_functiondef('public.here_targets(uuid, uuid, uuid, boolean)'::regprocedure);
    n := (length(d) - length(replace(d, 'interval ''100 seconds''', ''))) / length('interval ''100 seconds''');
    if n = 1 then execute replace(d, 'interval ''100 seconds''', 'public.presence_ttl()');
    elsif n <> 0 then raise exception 'here_targets changed: expected the window once, found %', n;
    end if;
  end if;
end $$;
