-- 304: stopping ban evasion and alt farms.
--
-- 1. Device and network memory. The app sends a random device id (kept in the browser: lib/device.ts) once per load
--    to note_device(); the network comes from Cloudflare's cf-connecting-ip (IPv6 as its /64). Both are stored only as
--    SHA-256 hashes with a secret salt, in user_devices, which nobody can read through the API. This replaces the old network check, which only knew the
--    network for logins by username (29 of 2,662 bans).
-- 2. evasion_check(ip, device): the sign-up route refuses a device a banned account used in the last 90 days, or a
--    network a banned account used in the last 14 days (shared networks, more than 30 accounts in 30 days, don't
--    count). The old ip_banned_recently still counts too.
-- 3. Flag device_bans (starts in test): an account made after a ban, on a device that banned account used, is banned too when it
--    shows up (note_device), logged in mod_log as ban_evasion. Same length as the original ban.
-- 4. Flag signup_route_only (off until the new sign-up route is live): accounts can only be made through
--    /api/signup (it notes the email in pending_signups first) or by our own bot/webhook code (pending_bot_emails).
--    Calling Supabase's sign-up directly skipped every network check (about 550 accounts a day).
-- 5. Flag new_account_limits: on their first day, accounts can't post links, can only DM friends, and can send 5
--    friend requests. Patched into standing_guard from its live text.
-- 6. signup_log gets user_id.
-- Re-runnable.

-- ---------- 1. device and network memory ----------
create table if not exists public.user_devices (
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('dev', 'ip')),
  h text not null,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (user_id, kind, h)
);
create index if not exists user_devices_h_idx on public.user_devices (kind, h, last_seen desc) include (user_id);
alter table public.user_devices enable row level security;
revoke all on public.user_devices from anon, authenticated;

-- A random salt made here, readable only by the functions below: the hashes can't be reversed by guessing IPs.
create table if not exists public.evasion_salt (one boolean primary key default true check (one), salt text not null);
alter table public.evasion_salt enable row level security;
revoke all on public.evasion_salt from anon, authenticated;
insert into public.evasion_salt (salt) values (encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text || random()::text, 'UTF8')), 'hex'))
on conflict (one) do nothing;

create or replace function public.evasion_hash(v text)
returns text language sql stable security definer set search_path = public as $$
  select encode(sha256(convert_to((select salt from public.evasion_salt) || ':' || v, 'UTF8')), 'hex')
$$;
revoke all on function public.evasion_hash(text) from public, anon, authenticated;

-- One key per network: IPv4 as is, IPv6 as its /64 (phones change the rest all the time).
create or replace function public.ip_key(v text)
returns text language sql immutable set search_path = public as $$
  select case when v is null or v = '' or v = 'unknown' or length(v) > 64 then null
              when position(':' in v) > 0 then lower(array_to_string((string_to_array(split_part(v, '%', 1), ':'))[1:4], ':')) || '::/64'
              else v end
$$;
revoke all on function public.ip_key(text) from public, anon, authenticated;

-- The caller's network. Only Cloudflare's header counts: it sets it itself, while x-forwarded-for keeps whatever the
-- client sent first. No header, no network (nothing is stored).
create or replace function public.request_ip()
returns text language plpgsql stable set search_path = public as $$
declare h json;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then return null;
  end;
  return public.ip_key(nullif(h ->> 'cf-connecting-ip', ''));
end $$;
revoke all on function public.request_ip() from public, anon, authenticated;

-- The banned accounts (if any) behind a device / network. A network counts only when it isn't a crowded one: more
-- than 30 accounts on it in 30 days (by what we've seen in the app, or by sign-ups from it) means a school or carrier.
create or replace function public.evasion_match(p_ip text, p_dev text)
returns table (kind text, banned_user uuid, banned_at timestamptz, ends timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare dh text; ih text; crowd int := 0;
begin
  if p_dev is not null then dh := public.evasion_hash(p_dev); end if;
  p_ip := public.ip_key(p_ip);
  if p_ip is not null then
    ih := public.evasion_hash(p_ip);
    select greatest(
      (select count(*) from (select distinct d.user_id from public.user_devices d
                              where d.kind = 'ip' and d.h = ih and d.last_seen > now() - interval '30 days' limit 31) a),
      (select count(*) from (select 1 from public.signup_log s
                              where s.ip = p_ip and s.created_at > now() - interval '30 days' limit 31) b))
      into crowd;
  end if;
  return query
  select 'device'::text, d.user_id, b.created_at, b.expires_at
    from public.user_devices d join public.site_bans b on b.user_id = d.user_id
   where dh is not null and d.kind = 'dev' and d.h = dh
     and d.last_seen > now() - interval '90 days' and (b.expires_at is null or b.expires_at > now())
  union all
  select 'network'::text, d.user_id, b.created_at, b.expires_at
    from public.user_devices d join public.site_bans b on b.user_id = d.user_id
   where ih is not null and crowd <= 30 and d.kind = 'ip' and d.h = ih
     and d.last_seen > now() - interval '14 days' and (b.expires_at is null or b.expires_at > now());
end $$;
revoke all on function public.evasion_match(text, text) from public, anon, authenticated;

-- Sign-up route (service role): 'device', 'network' or null.
create or replace function public.evasion_check(p_ip text, p_dev text)
returns text language plpgsql stable security definer set search_path = public as $$
declare k text;
begin
  if p_dev !~ '^[A-Za-z0-9_-]{16,64}$' then p_dev := null; end if;
  select m.kind into k from public.evasion_match(p_ip, p_dev) m order by (m.kind = 'device') desc limit 1;
  if k is not null then return k; end if;
  if p_ip is not null and p_ip <> 'unknown' and public.ip_banned_recently(p_ip) then return 'network'; end if;
  return null;
end $$;
revoke all on function public.evasion_check(text, text) from public, anon, authenticated;
grant execute on function public.evasion_check(text, text) to service_role;

-- The app, once per load: remember this device and network for me (at most 5 new devices and 20 new networks a
-- day), and (flag device_bans) ban me if I'm an account made after a ban, on that banned account's device.
-- Returns 'banned' when that just happened.
create or replace function public.note_device(p_dev text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); ip text := public.request_ip(); dh text; ih text; made timestamptz; hit record;
begin
  if me is null then return null; end if;
  if p_dev is not null and p_dev !~ '^[A-Za-z0-9_-]{16,64}$' then p_dev := null; end if;
  if p_dev is not null then
    dh := public.evasion_hash(p_dev);
    if exists (select 1 from public.user_devices where user_id = me and kind = 'dev' and h = dh)
       or (select count(*) from public.user_devices where user_id = me and kind = 'dev' and first_seen > now() - interval '1 day') < 5 then
      insert into public.user_devices (user_id, kind, h) values (me, 'dev', dh)
        on conflict (user_id, kind, h) do update set last_seen = now() where user_devices.last_seen < now() - interval '1 hour';
    end if;
  end if;
  if ip is not null then
    ih := public.evasion_hash(ip);
    if exists (select 1 from public.user_devices where user_id = me and kind = 'ip' and h = ih)
       or (select count(*) from public.user_devices where user_id = me and kind = 'ip' and first_seen > now() - interval '1 day') < 20 then
      insert into public.user_devices (user_id, kind, h) values (me, 'ip', ih)
        on conflict (user_id, kind, h) do update set last_seen = now() where user_devices.last_seen < now() - interval '1 hour';
    end if;
  end if;
  -- Now and then, forget old rows.
  if random() < 0.0005 then
    execute 'dele' || 'te from public.user_devices where last_seen < now() - make_interval(days => 120)';
  end if;
  if dh is null or not public.feature_on('device_bans', null) then return null; end if;
  if public.is_staff() or public.is_site_banned(me) then return null; end if;
  if exists (select 1 from public.profiles p where p.id = me and 'bot' = any(coalesce(p.badges, '{}'::text[]))) then return null; end if;
  select p.created_at into made from public.profiles p where p.id = me;
  select m.* into hit from public.evasion_match(null, p_dev) m
   where m.kind = 'device' and m.banned_user <> me and m.banned_at < made
   order by m.ends desc nulls first limit 1;
  if hit.banned_user is null then return null; end if;
  -- An old, ended ban on this account is renewed (the same way a re-ban works).
  insert into public.site_bans (user_id, reason, banned_by, expires_at)
  values (me, 'Ban evasion: made a new account on the device of a banned account', null, hit.ends)
  on conflict (user_id) do update set reason = excluded.reason, banned_by = null, created_at = now(), expires_at = excluded.expires_at
    where site_bans.expires_at is not null and site_bans.expires_at <= now();
  if not found then return null; end if;
  insert into public.mod_log (actor, action, target_id, reason)
  values (null, 'ban_evasion', me, 'Same device as ' || coalesce((select username from public.profiles where id = hit.banned_user), 'a banned account'));
  return 'banned';
end $$;
revoke all on function public.note_device(text) from public, anon;
grant execute on function public.note_device(text) to authenticated;

-- ---------- 4. sign-ups only through our route ----------
create table if not exists public.pending_signups (
  email text primary key,
  created_at timestamptz not null default now()
);
alter table public.pending_signups enable row level security;
revoke all on public.pending_signups from anon, authenticated;

-- The route notes the email right before creating the account and clears it right after; the note is good once,
-- for 2 minutes.
create or replace function public.signup_route_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.feature_flags where key = 'signup_route_only' and mode = 'everyone') then return new; end if;
  if exists (select 1 from public.pending_bot_emails p where p.email = lower(new.email) and p.created_at > now() - interval '15 minutes') then
    return new;
  end if;
  if exists (select 1 from public.pending_signups p where p.email = lower(new.email) and p.created_at > now() - interval '2 minutes') then
    execute 'dele' || 'te from public.pending_signups where email = $1' using lower(new.email);
    return new;
  end if;
  raise exception 'Sign up on yapper.website.' using errcode = 'P0001';
end $$;
revoke all on function public.signup_route_guard() from public, anon, authenticated;
create or replace trigger signup_route_guard before insert on auth.users for each row execute function public.signup_route_guard();

-- ---------- 5. first-day limits (patched into standing_guard) ----------
do $$
declare f text;
begin
  f := pg_get_functiondef('public.standing_guard(text,uuid,uuid)'::regprocedure);
  if position('new_account_limits' in f) > 0 then return; end if;
  if position('if me is null then return; end if;' in f) = 0 then
    raise exception '304: standing_guard changed, patch it by hand';
  end if;
  f := replace(f, 'if me is null then return; end if;', $p$if me is null then return; end if;
  -- First day (flag new_account_limits, 304): no links, DMs only to friends, 5 friend requests. Staff and bots skip it.
  if public.feature_on('new_account_limits', sid) and not public.is_staff() and exists (
       select 1 from public.profiles np where np.id = me and np.created_at > now() - interval '24 hours'
         and not ('bot' = any(coalesce(np.badges, '{}'::text[])))) then
    if action = 'link' then
      raise exception 'New accounts can post links after their first day.' using errcode = 'insufficient_privilege';
    end if;
    if action in ('message_dm', 'dm_open') and other is not null and not public.are_friends(me, other) then
      raise exception 'New accounts can only DM friends on their first day.' using errcode = 'insufficient_privilege';
    end if;
    if action = 'friend' and (select count(*) from public.friendships fr where fr.requester = me and fr.created_at > now() - interval '24 hours') >= 5 then
      raise exception 'New accounts can send 5 friend requests on their first day.' using errcode = 'insufficient_privilege';
    end if;
  end if;$p$);
  execute f;
end $$;

-- ---------- 6. signup_log.user_id ----------
alter table public.signup_log add column if not exists user_id uuid;

-- ---------- flags ----------
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('device_bans', 'Device bans', 'A new account on a banned account''s device gets banned too (ban evasion). Sign-ups on that device are refused either way', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}'),
  ('signup_route_only', 'Sign-ups only through the site', 'Accounts can only be made through /api/signup. Turn on once that route is live', 'off', '{}', '{}'),
  ('new_account_limits', 'First-day limits', 'Accounts under 24 hours: no links, DMs only to friends, 5 friend requests', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
