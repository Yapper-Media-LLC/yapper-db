-- "Playing X" and custom statuses, like Discord.
--   profiles.custom_status   a short line you set yourself ("studying", "on vacation")
--   presence.activity        what the desktop app sees you running ({"name": "Fortnite", "since": ...}),
--                            sent with every heartbeat and handed out by who_online.

alter table public.profiles add column if not exists custom_status text;
alter table public.profiles drop constraint if exists custom_status_len;
alter table public.profiles add constraint custom_status_len check (custom_status is null or char_length(custom_status) <= 80);
grant select (custom_status) on public.profiles to anon, authenticated;
grant update (custom_status) on public.profiles to authenticated;

alter table public.presence add column if not exists activity jsonb;
alter table public.presence add column if not exists activity_at timestamptz;

create or replace function public.heartbeat(st text, act jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); prev timestamptz; gap int; a jsonb;
begin
  if me is null then return; end if;
  if st is null or st = 'invisible' or st = 'off' then
    update public.presence set last_seen = now() - interval '100 seconds' where user_id = me and last_seen > now() - interval '100 seconds';
    return;
  end if;
  if st not in ('online', 'idle', 'dnd') then st := 'online'; end if;
  -- Only a name (and when it started) is kept; nothing else from the client.
  if act is not null and jsonb_typeof(act) = 'object' and coalesce(act->>'name', '') <> '' then
    a := jsonb_build_object('name', left(act->>'name', 60), 'since', coalesce(act->>'since', now()::text));
  end if;
  select last_seen into prev from public.presence where user_id = me;
  if prev is not null and prev > now() - interval '100 seconds' then
    gap := least(60, greatest(0, extract(epoch from (now() - prev))::int));
    insert into public.online_time (user_id, day, secs) values (me, current_date, gap)
      on conflict (user_id, day) do update set secs = online_time.secs + excluded.secs;
  end if;
  insert into public.presence (user_id, status, activity, activity_at) values (me, st, a, case when a is null then null else now() end)
  on conflict (user_id) do update set
    last_seen = now(),
    online_since = case when presence.last_seen < now() - interval '100 seconds' then now() else presence.online_since end,
    status = excluded.status,
    status_at = case when presence.status is distinct from excluded.status then now() else presence.status_at end,
    activity = case when (presence.activity->>'name') is distinct from (excluded.activity->>'name') then excluded.activity else presence.activity end,
    activity_at = case when (presence.activity->>'name') is distinct from (excluded.activity->>'name') then now() else presence.activity_at end;
end; $$;

create or replace function public.who_online(sid uuid, extra uuid[], since timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  ttl interval := interval '100 seconds';
  ids uuid[] := (coalesce(extra, '{}'::uuid[]))[1:500];
  rows jsonb;
begin
  if me is null then return '{}'::jsonb; end if;
  if sid is not null and not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then sid := null; end if;
  select coalesce(jsonb_agg(jsonb_build_array(p.user_id, case when p.last_seen > now() - ttl then p.status else 'off' end, p.activity)), '[]'::jsonb)
    into rows
  from public.presence p
  where p.last_seen > now() - ttl - (case when since is null then interval '0' else ttl end)
    and (p.user_id = any(ids) or (sid is not null and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.user_id)))
    and (
      (since is null and p.last_seen > now() - ttl)
      or (since is not null and (p.online_since > since or p.status_at > since or p.activity_at > since or (p.last_seen <= now() - ttl and p.last_seen > since - ttl)))
    );
  return jsonb_build_object('now', now(), 'rows', rows);
end; $$;

insert into public.feature_flags (key, label, description, mode, users)
  values ('activity', 'Activity and custom status', 'Shows what people are playing (desktop app) and the status line they set', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
  on conflict (key) do nothing;
