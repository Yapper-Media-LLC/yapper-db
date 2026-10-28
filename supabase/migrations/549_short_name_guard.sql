-- 549: two rules against username sniping (Antic, Oct 26: a former contributor kept idle accounts named error, work,
-- manage, ... as stock and sold short names for crypto). Flag `short_name_guard`, mode test.
--
-- 1. Hoarded short names are released. A username of 4 characters or fewer on a human account with fewer than
--    20 messages and nothing seen from it for 14 days (no sign-in, no app open: auth.users.last_sign_in_at and
--    user_devices.last_seen, 304) is given back: the account is renamed to userXXXXXXXX (the shape
--    mod_reset_profile uses, 277) and the short name is free at once (no 7-day hold: the rename runs as the cron
--    role, which username_holds_guard leaves alone, and any hold the account itself had on the name is ended).
--    One mod_log row per release (short_name_release, actor Antic like 529). There is no in-app notice path for a
--    single account (user_warnings would count as a warning), so the person finds out on their next visit.
--    Never: staff, verified, Plus, site-banned (their names are held on purpose, 530), bots, the owner.
--    release_short_names(dry) does the work; cron runs it daily at 04:50 UTC (short-name-release). While the flag is
--    'test' only accounts listed in the flag's users are renamed; 'everyone' renames all that match; 'off' does
--    nothing. select * from public.release_short_names(true) lists what would go without changing anything, in any
--    mode. At most 200 accounts per run.
-- 2. Claiming a short name is gated. A username of 4 characters or fewer needs an account that is 7 days old with
--    10 messages sent, or Plus. On rename: short_name_claim_guard (a BEFORE trigger next to the other username
--    guards) refuses real users' own renames with 'Short names (4 letters or less) are for accounts that are a week
--    old with 10 messages sent, or have Plus.' once the flag is on for them. Staff and server-side work go through.
--    At sign-up nobody is a week old, so a short name can't be picked there once the flag is 'everyone':
--    /api/signup says so (srv_short_name_blocked), and if one gets through anyway the same trigger swaps it for a
--    userXXXXXXXX name on insert (bots excepted, their metadata says bot). Test mode leaves sign-ups alone, like 530.
--    An account whose name was released (1.) can't take a short name for 30 days, Plus or not, so a hoard account
--    with 10 to 19 messages can't claim it back the next morning. Bots are never released and skip the rename gate,
--    so /api/bots refuses bot names of 4 characters or fewer with the same srv_short_name_blocked check.
--
-- Re-runnable. DDL (functions, one trigger, one cron row): apply in quiet hours, one go. No row removal.

set lock_timeout = '2s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('short_name_guard', 'Short username rules',
  'Idle accounts (under 20 messages, nothing seen for 14 days) lose usernames of 4 characters or fewer, and taking one needs a week-old account with 10 messages or Plus',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- A fresh userXXXXXXXX name nobody has (same shape as mod_reset_profile, 277).
create or replace function public.fresh_user_name(uid uuid)
returns text language plpgsql set search_path = public as $$
declare n text;
begin
  loop
    n := 'user' || substr(md5(random()::text || uid::text), 1, 8);
    exit when not exists (select 1 from public.profiles p where lower(p.username) = n);
  end loop;
  return n;
end $$;
revoke all on function public.fresh_user_name(uuid) from public, anon, authenticated;

-- ---------- 1. release hoarded short names ----------
create or replace function public.release_short_names(dry boolean default false)
returns table (user_id uuid, username text, messages int, last_seen timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  antic constant uuid := '00000000-0000-4000-8000-00000000a001';
  max_msgs constant int := 20;
  idle constant interval := '14 days';
  mode text := coalesce((select f.mode from public.feature_flags f where f.key = 'short_name_guard'), 'off');
  testers uuid[] := coalesce((select f.users from public.feature_flags f where f.key = 'short_name_guard'), '{}');
  r record;
  fresh text;
begin
  dry := coalesce(dry, false);
  if not dry and mode = 'off' then return; end if;
  for r in
    select p.id, p.username,
           (select count(*) from (select 1 from public.messages m where m.author_id = p.id limit max_msgs) s)::int as msgs,
           greatest(p.created_at, u.last_sign_in_at,
                    (select max(d.last_seen) from public.user_devices d where d.user_id = p.id)) as seen
      from public.profiles p join auth.users u on u.id = p.id
     where char_length(p.username) <= 4
       and p.id <> antic
       and (dry or mode = 'everyone' or p.id = any(testers))
       and p.verified_as is null
       and (p.plus_until is null or p.plus_until <= now())
       and coalesce(u.raw_user_meta_data ->> 'bot', '') <> 'true'
       and not exists (select 1 from public.bots x where x.id = p.id)
       and not exists (select 1 from public.bot_accounts ba where ba.user_id = p.id)
       and not exists (select 1 from public.site_admins a where a.user_id = p.id)
       and not exists (select 1 from public.site_moderators m where m.user_id = p.id)
       and not exists (select 1 from public.site_bans b where b.user_id = p.id and (b.expires_at is null or b.expires_at > now()))
       and p.created_at < now() - idle
       and coalesce(u.last_sign_in_at, p.created_at) < now() - idle
       and not exists (select 1 from public.user_devices d where d.user_id = p.id and d.last_seen >= now() - idle)
       and (select count(*) from (select 1 from public.messages m where m.author_id = p.id limit max_msgs) s) < max_msgs
     order by p.created_at
     limit 200
  loop
    user_id := r.id; username := r.username; messages := r.msgs; last_seen := r.seen;
    if not dry then
      -- Same lock the holds trigger and mod_reset_profile take, so a rename grabbing this name waits for us.
      perform pg_advisory_xact_lock(hashtext('username:' || lower(r.username)));
      fresh := public.fresh_user_name(r.id);
      update public.profiles p set username = fresh where p.id = r.id and p.username = r.username;
      if not found then continue; end if;
      -- A hold the account itself has on the name would let it take the name straight back.
      update public.username_holds h set until = now() where h.name_key = lower(r.username) and h.user_id = r.id and h.until > now();
      insert into public.mod_log (actor, action, target_id, reason)
      values (antic, 'short_name_release', r.id,
              format('Short name %s released: %s messages, nothing seen since %s. Renamed to %s',
                     r.username, r.msgs, to_char(r.seen at time zone 'UTC', 'YYYY-MM-DD'), fresh));
    end if;
    return next;
  end loop;
end $$;
revoke all on function public.release_short_names(boolean) from public, anon, authenticated;

-- ---------- 2. gate on claiming a short name ----------
create or replace function public.short_name_claim_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  min_age constant interval := '7 days';
  min_msgs constant int := 10;
  mode text;
  n int;
begin
  if new.username is null or char_length(new.username) > 4 then return new; end if;
  if tg_op = 'UPDATE' and lower(new.username) is not distinct from lower(old.username) then return new; end if;
  mode := coalesce((select f.mode from public.feature_flags f where f.key = 'short_name_guard'), 'off');
  if mode = 'off' then return new; end if;

  if tg_op = 'INSERT' then
    -- Sign-up: nobody is a week old yet. Only once the flag is on for everyone (no way to tell a tester here).
    if mode <> 'everyone' then return new; end if;
    if exists (select 1 from auth.users u where u.id = new.id and coalesce(u.raw_user_meta_data ->> 'bot', '') = 'true') then return new; end if;
    new.username := public.fresh_user_name(new.id);
    return new;
  end if;

  -- Real user requests on their own name, like the other username guards. Staff and server-side work go through.
  if coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
     or (select auth.uid()) is distinct from new.id or public.is_staff() then return new; end if;
  if not public.feature_on_for_me('short_name_guard') then return new; end if;
  -- An account whose short name was just released (10 to 19 messages pass the gate below) can't take one back for
  -- 30 days, or the hoarder's script would reclaim it at 04:51.
  if exists (select 1 from public.mod_log l where l.action = 'short_name_release' and l.target_id = new.id
              and l.created_at > now() - interval '30 days') then
    raise exception 'A short name of yours was released because the account sat unused. You can pick a short one again in 30 days.'
      using errcode = 'check_violation';
  end if;
  if old.plus_until is not null and old.plus_until > now() then return new; end if;

  select count(*) into n from (select 1 from public.messages m where m.author_id = new.id limit min_msgs) s;
  if old.created_at > now() - min_age or n < min_msgs then
    raise exception 'Short names (4 letters or less) are for accounts that are a week old with 10 messages sent, or have Plus.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
revoke all on function public.short_name_claim_guard() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'profiles_username_short_name' and tgrelid = 'public.profiles'::regclass) then
    create trigger profiles_username_short_name before insert or update of username on public.profiles
      for each row execute function public.short_name_claim_guard();
  end if;
end $$;

-- /api/signup (service role) asks before creating the account, so the person gets a clear answer.
create or replace function public.srv_short_name_blocked(name text)
returns boolean language sql stable security definer set search_path = public as $$
  select char_length(coalesce(name, '')) <= 4
     and exists (select 1 from public.feature_flags f where f.key = 'short_name_guard' and f.mode = 'everyone');
$$;
revoke all on function public.srv_short_name_blocked(text) from public, anon, authenticated;
grant execute on function public.srv_short_name_blocked(text) to service_role;

-- ---------- daily run ----------
-- Remove with select cron.unschedule('short-name-release').
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'short-name-release') then
      perform cron.schedule('short-name-release', '50 4 * * *', 'select public.release_short_names()');
    end if;
  end if;
end $$;

reset lock_timeout;
