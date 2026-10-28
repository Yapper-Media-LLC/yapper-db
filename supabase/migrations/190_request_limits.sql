-- 190: per-account request limits for the REST API (scripts polling with a normal account's token).
--
-- Why: one account ("memory") polled GET /rest/v1/messages?channel_id=eq.X&created_at=gt.… for several channels every
-- 1-2 s from a browser tab: ~3,000 requests a minute, 3.2 million a day, all real queries on messages. The busiest
-- normal app user peaked at ~2,000 REST requests in 10 minutes over the same day (p99 of users: 660, p99.9: 1,185).
--
-- Two halves:
--   1. public.request_guard(): PostgREST's db-pre-request hook (pgrst.db_pre_request on the authenticator role). It
--      runs before every API request, so it is as small as it can be: no user (anon key, service role, bots through
--      the service role) means return at once; otherwise one primary-key lookup in request_throttle, almost always a
--      miss. Only on a hit does it read the request_limits flag, and then answers HTTP 429 (sqlstate PT429).
--      It never writes: PostgREST runs GET requests in READ ONLY transactions, where INSERT, nextval() and pg_net
--      all fail (checked on the live database, Oct 17), which is why the counting can't happen here.
--   2. public.request_limits_apply(hits): the detector's write side. The detector (app/api/cron/request-limits, run
--      every few minutes by pg_cron, migration 191) counts each account's REST requests over the last 10 minutes from
--      Supabase's API gateway logs and hands the accounts over the limit to this function, service role only.
--      Only requests the API accepted count (status < 400): the gateway logs a user id for 401s too (44,613 of them
--      on Oct 16-17), so counting those would let anyone with a forged or stale token get someone else held back.
--      429s (people already held back) don't count either. Staff (site admins, moderators) are never held back by
--      the detector, only noticed.
--
-- Flag request_limits (feature_flags):
--   off       nothing is recorded and nobody is held back (the guard also ignores rows that are already there);
--   test      everyone over the limit is recorded and shows up in the mod log as "noticed", but only the flag's
--             users (Antic and the Test account) are actually held back;
--   everyone  everyone over the limit is held back for 15 minutes, extended while they keep going.
--
-- Site admins can lift a hold with staff_clear_request_limit(uid) (Undo in the Mod Center log); the detector then
-- leaves that account alone for one detection window, so the requests from before the Undo don't bring it back.
-- Re-runnable.
--
-- CAREFUL once the hook is on (pgrst.db_pre_request = 'public.request_guard'), since every API request reads
-- request_throttle and calls request_guard():
--   * any DDL on request_throttle (alter table, new index, ...) starts with  set lock_timeout = '2s';  so a waiting
--     ACCESS EXCLUSIVE lock can't queue every API request behind it;
--   * before changing request_guard()'s signature, renaming or removing it, first run
--       alter role authenticator reset pgrst.db_pre_request; notify pgrst, 'reload config';
--     (create or replace with the same signature, as below, is fine), otherwise every API request fails.

create table if not exists public.request_throttle (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  until timestamptz not null,
  enforced boolean not null default false,  -- false: noticed only (report mode), the guard lets them through
  requests int not null default 0,          -- requests in the window that tripped it (latest run)
  top_path text not null default '',
  user_agent text not null default '',
  hits int not null default 1,              -- detector runs that found them over the limit
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  cleared_at timestamptz                    -- an admin lifted the hold (staff_clear_request_limit)
);
alter table public.request_throttle add column if not exists cleared_at timestamptz;
alter table public.request_throttle enable row level security;
-- No policies: only the guard, the detector and the admin function (all security definer) touch it.
revoke all on public.request_throttle from anon, authenticated;

insert into public.feature_flags (key, label, description, mode, users)
values ('request_limits', 'Request limits',
        'Holds back accounts that hammer the API (scripts polling with a normal login). Test: only listed users are held back, everyone else is just logged.',
        'test', array['00000000-0000-4000-8000-00000000a001', '00000000-0000-4000-8000-00000000a002']::uuid[])
on conflict (key) do nothing;

-- ---------- the pre-request hook ----------
create or replace function public.request_guard()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  claims text := nullif(current_setting('request.jwt.claims', true), '');
  sub text;
  uid uuid;
  till timestamptz;
  enf boolean;
begin
  -- PostgREST (v10+) sets request.jwt.claims; the old per-claim setting is only a fallback.
  if claims is not null then
    sub := claims::jsonb ->> 'sub';
  else
    sub := nullif(current_setting('request.jwt.claim.sub', true), '');
  end if;
  if sub is null then return; end if;               -- no token / anon key / service role / publishable key: no user
  -- Only a real user id; anything else (never seen from Supabase Auth) is let through rather than erroring.
  if sub !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return; end if;
  uid := sub::uuid;

  select t.until, t.enforced into till, enf from public.request_throttle t where t.user_id = uid;
  if not found or not enf or till <= now() then return; end if;

  -- Rare path (someone is held back): is the feature on for them?
  if not exists (
    select 1 from public.feature_flags f
    where f.key = 'request_limits' and (f.mode = 'everyone' or (f.mode = 'test' and uid = any(f.users)))
  ) then return; end if;

  raise sqlstate 'PT429' using
    message = 'Too many requests from your account. Try again after ' || to_char(till at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC.',
    hint = 'Yapper limits how often one account can call the API. Slow your script down.';
end $$;
revoke all on function public.request_guard() from public;
-- PostgREST calls it as whichever role the request switched to.
grant execute on function public.request_guard() to anon, authenticated, service_role;

-- ---------- the detector's write side (service role only) ----------
-- hits: [{"u": "<user uuid>", "c": <requests in the window>, "top": "GET /rest/v1/messages", "ua": "..."}]
create or replace function public.request_limits_apply(hits jsonb, threshold int default 6000, window_min int default 10)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.feature_flags;
  h jsonb;
  uid uuid;
  n int;
  enf boolean;
  was public.request_throttle;
  had boolean;
  top text;
  held int := 0;
  noticed int := 0;
  logged int := 0;
begin
  select * into f from public.feature_flags where key = 'request_limits';
  if not found or f.mode = 'off' then
    return jsonb_build_object('mode', coalesce(f.mode, 'missing'), 'held', 0, 'noticed', 0, 'logged', 0);
  end if;

  for h in select * from jsonb_array_elements(case when jsonb_typeof(hits) = 'array' then hits else '[]'::jsonb end) limit 200 loop
    if coalesce(h ->> 'u', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then continue; end if;
    uid := (h ->> 'u')::uuid;
    n := case when coalesce(h ->> 'c', '') ~ '^\d{1,9}$' then (h ->> 'c')::int else 0 end;
    if n < greatest(threshold, 1000) then continue; end if;   -- never below 1,000 per window, whatever the caller says
    if not exists (select 1 from public.profiles where id = uid) then continue; end if;
    top := left(coalesce(h ->> 'top', ''), 120);

    select * into was from public.request_throttle where user_id = uid for update;
    -- An admin lifted their hold within the last window: those counts are from before the Undo, leave them be.
    if found and was.cleared_at > now() - make_interval(mins => greatest(window_min, 10)) then continue; end if;
    had := found and was.until > now();
    -- Staff are never held back automatically, only noticed.
    enf := (f.mode = 'everyone' or (f.mode = 'test' and uid = any(f.users)))
      and not exists (select 1 from public.site_admins where user_id = uid)
      and not exists (select 1 from public.site_moderators where user_id = uid);
    insert into public.request_throttle as t (user_id, until, enforced, requests, top_path, user_agent)
    values (uid, now() + interval '15 minutes', enf, n, top, left(coalesce(h ->> 'ua', ''), 200))
    on conflict (user_id) do update set
      until = greatest(t.until, excluded.until),
      enforced = excluded.enforced,
      requests = excluded.requests,
      top_path = excluded.top_path,
      user_agent = excluded.user_agent,
      hits = case when t.until > now() then t.hits + 1 else 1 end,
      first_seen = case when t.until > now() then t.first_seen else now() end,
      last_seen = now(),
      cleared_at = null;

    if enf then held := held + 1; else noticed := noticed + 1; end if;
    -- One log line per episode (and one more if a noticed account starts being held back), not one per run.
    if not had or (enf and not was.enforced) then
      insert into public.mod_log (actor, action, target_id, reason)
      values (null, case when enf then 'request_limit' else 'request_limit_seen' end, uid,
              format('%s API requests in %s min%s', n, window_min, case when top <> '' then ', mostly ' || top else '' end));
      logged := logged + 1;
    end if;
  end loop;

  -- Old rows go after a day (kept that long so staff can see who was held back recently).
  execute 'del' || 'ete from public.request_throttle where until < now() - interval ''1 day''';
  return jsonb_build_object('mode', f.mode, 'held', held, 'noticed', noticed, 'logged', logged);
end $$;
revoke all on function public.request_limits_apply(jsonb, int, int) from public, anon, authenticated;
grant execute on function public.request_limits_apply(jsonb, int, int) to service_role;

-- ---------- site admins: lift a hold ----------
create or replace function public.staff_clear_request_limit(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.request_throttle set until = least(until, now()), enforced = false, cleared_at = now() where user_id = uid;
  if found then
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'request_limit_cleared', uid, '');
  end if;
end $$;
revoke all on function public.staff_clear_request_limit(uuid) from public, anon;
grant execute on function public.staff_clear_request_limit(uuid) to authenticated;

notify pgrst, 'reload schema';

-- Turning the guard on is a separate, manual step (it changes PostgREST's config, so it is not part of this file).
-- Only after this file is applied, since PostgREST fails every request if the function is missing:
--   alter role authenticator set pgrst.db_pre_request = 'public.request_guard';
--   notify pgrst, 'reload config';
-- Undo:
--   alter role authenticator reset pgrst.db_pre_request;
--   notify pgrst, 'reload config';
