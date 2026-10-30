-- 660: ways back in for people who lost their authenticator (flag mfa_recovery).
--   1. Backup codes: 10 one-time codes, stored only as sha256(user id : code). Shown once, never readable back.
--   2. "Lost your phone?": after the password step, a mail with a link that turns 2FA off once 24 hours have passed,
--      plus a cancel link. Tokens are stored only as hashes too.
--   3. security_log: every try, success, refusal and staff removal, for rate limits and for support.
-- Everything here is for the API routes (service role) only: the tables have RLS on and no policies for users (staff
-- read security_log), and the functions are revoked from anon and authenticated. The routes check who is asking
-- (password session, aal2, site admin) before calling them; removing the authenticator itself goes through the
-- Supabase Auth admin API, not SQL. Old codes and requests are marked used or cancelled, never deleted (the MCP hangs on deletes).
-- Only built-ins (sha256, gen_random_uuid), so no extension schema is needed.

create table if not exists public.security_log (
  id bigint generated always as identity primary key,
  user_id uuid,              -- no foreign key: the trail outlives the account
  actor uuid,                -- staff member for staff actions, else null
  event text not null,
  ip text,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists security_log_user_idx on public.security_log (user_id, event, created_at desc);
create index if not exists security_log_ip_idx on public.security_log (ip, event, created_at desc);
create index if not exists security_log_time_idx on public.security_log (created_at desc);
alter table public.security_log enable row level security;
revoke all on public.security_log from anon, authenticated;
grant select on public.security_log to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'security_log' and policyname = 'admins read the security log') then
    create policy "admins read the security log" on public.security_log for select to authenticated using ((select public.is_site_admin()));
  end if;
end $$;

create table if not exists public.mfa_backup_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  code_hash text not null,
  created_at timestamptz not null default now(),
  used_at timestamptz,
  revoked_at timestamptz
);
create index if not exists mfa_backup_codes_user_idx on public.mfa_backup_codes (user_id) where used_at is null and revoked_at is null;
create index if not exists mfa_backup_codes_user_fk_idx on public.mfa_backup_codes (user_id);
alter table public.mfa_backup_codes enable row level security;
revoke all on public.mfa_backup_codes from anon, authenticated;

create table if not exists public.mfa_recovery_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  confirm_hash text not null unique,
  cancel_hash text not null unique,
  status text not null default 'pending' check (status in ('pending', 'done', 'cancelled')),
  created_at timestamptz not null default now(),
  ready_at timestamptz not null,
  expires_at timestamptz not null,
  closed_at timestamptz
);
create index if not exists mfa_recovery_requests_user_idx on public.mfa_recovery_requests (user_id, created_at desc);
alter table public.mfa_recovery_requests enable row level security;
revoke all on public.mfa_recovery_requests from anon, authenticated;

create or replace function public.mfa_hash(p_salt text, p_secret text)
returns text language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(p_salt || ':' || p_secret, 'UTF8')), 'hex');
$$;

-- 10 random characters from 32 easy-to-read ones (no 0, 1, l, o): 50 bits, typed as xxxxx-xxxxx.
create or replace function public.mfa_new_code()
returns text language plpgsql volatile set search_path = public as $$
declare
  abc constant text := '23456789abcdefghijkmnpqrstuvwxyz';
  b bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  idx int[] := array[0, 1, 2, 3, 4, 5, 9, 10, 11, 12]; -- skips bytes 6-8, which carry the uuid version and variant bits
  out text := '';
  i int;
begin
  foreach i in array idx loop
    out := out || substr(abc, (get_byte(b, i) & 31) + 1, 1);
  end loop;
  return out;
end;
$$;

create or replace function public.mfa_log(p_user uuid, p_event text, p_ip text, p_detail jsonb default '{}', p_actor uuid default null)
returns void language sql security definer set search_path = public as $$
  insert into public.security_log (user_id, actor, event, ip, detail) values (p_user, p_actor, left(p_event, 60), left(p_ip, 64), coalesce(p_detail, '{}'));
$$;

-- New set of codes; the old unused ones stop working. Returns the 10 codes, the only time they exist in plain text.
create or replace function public.mfa_backup_codes_new(p_user uuid, p_ip text)
returns text[] language plpgsql security definer set search_path = public as $$
declare codes text[] := '{}'; c text; n int;
begin
  if p_user is null then raise exception 'No user'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mfa:' || p_user::text, 0));
  select count(*) into n from public.security_log where user_id = p_user and event = 'backup_codes_new' and created_at > now() - interval '1 day';
  if n >= 10 then raise exception 'You made new codes a lot today. Try again tomorrow'; end if;
  update public.mfa_backup_codes set revoked_at = now() where user_id = p_user and used_at is null and revoked_at is null;
  for i in 1..10 loop
    c := public.mfa_new_code();
    codes := codes || c;
    insert into public.mfa_backup_codes (user_id, code_hash) values (p_user, public.mfa_hash(p_user::text, c));
  end loop;
  perform public.mfa_log(p_user, 'backup_codes_new', p_ip);
  return codes;
end;
$$;

-- What Settings and the Mod Center show: codes left, and a pending email reset if there is one.
create or replace function public.mfa_recovery_status(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'codes_left', (select count(*) from public.mfa_backup_codes where user_id = p_user and used_at is null and revoked_at is null),
    'pending', (select jsonb_build_object('created_at', created_at, 'ready_at', ready_at) from public.mfa_recovery_requests
                 where user_id = p_user and status = 'pending' and expires_at > now() order by created_at desc limit 1));
$$;

-- Try a backup code. Returns {ok, id} or {error}; it never raises on a wrong code, so the failed try is counted.
-- Wrong codes: 5 per 15 minutes and 20 per day per account, 30 per hour per IP. p_since (the newest authenticator's
-- created_at, from the route) makes codes from before it dead, should a turn-off ever skip mfa_cleared.
create or replace function public.mfa_backup_code_use(p_user uuid, p_code text, p_ip text, p_since timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c text := lower(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); hit uuid;
begin
  if p_user is null then raise exception 'No user'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mfa:' || p_user::text, 0));
  if (select count(*) from public.security_log where user_id = p_user and event = 'backup_code_fail' and created_at > now() - interval '15 minutes') >= 5
     or (select count(*) from public.security_log where user_id = p_user and event = 'backup_code_fail' and created_at > now() - interval '1 day') >= 20
     or (p_ip is not null and (select count(*) from public.security_log where ip = left(p_ip, 64) and event = 'backup_code_fail' and created_at > now() - interval '1 hour') >= 30) then
    perform public.mfa_log(p_user, 'backup_code_limited', p_ip);
    return jsonb_build_object('error', 'Too many wrong codes. Wait a bit and try again.');
  end if;
  if length(c) = 10 then
    update public.mfa_backup_codes set used_at = now()
     where id = (select id from public.mfa_backup_codes where user_id = p_user and code_hash = public.mfa_hash(p_user::text, c)
                  and used_at is null and revoked_at is null and (p_since is null or created_at >= p_since) limit 1)
    returning id into hit;
  end if;
  if hit is null then
    perform public.mfa_log(p_user, 'backup_code_fail', p_ip);
    return jsonb_build_object('error', 'That code didn’t work. Each code works once.');
  end if;
  perform public.mfa_log(p_user, 'backup_code_used', p_ip, jsonb_build_object('code_id', hit));
  return jsonb_build_object('ok', true, 'id', hit);
end;
$$;

-- The route couldn't remove the authenticator after a good code: give the code back.
create or replace function public.mfa_backup_code_unuse(p_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.mfa_backup_codes set used_at = null where id = p_id and revoked_at is null;
$$;

-- 2FA is gone (any way): no codes or pending resets are left behind for the next time it's turned on.
create or replace function public.mfa_cleared(p_user uuid)
returns void language sql security definer set search_path = public as $$
  update public.mfa_backup_codes set revoked_at = now() where user_id = p_user and used_at is null and revoked_at is null;
  update public.mfa_recovery_requests set status = 'cancelled', closed_at = now() where user_id = p_user and status = 'pending';
$$;

-- "Lost your phone?" Returns {confirm, cancel, ready_at} (tokens in plain text, only here, for the mail) or {error}.
-- One open request at a time; at most 3 a day.
create or replace function public.mfa_recovery_start(p_user uuid, p_ip text, p_wait interval default interval '24 hours')
returns jsonb language plpgsql security definer set search_path = public as $$
declare t1 text; t2 text; r public.mfa_recovery_requests;
begin
  if p_user is null then raise exception 'No user'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mfa:' || p_user::text, 0));
  if exists (select 1 from public.mfa_recovery_requests where user_id = p_user and status = 'pending' and expires_at > now()) then
    return jsonb_build_object('error', 'We already sent you a link. Check your inbox and spam folder.');
  end if;
  if (select count(*) from public.security_log where user_id = p_user and event = 'recovery_start' and created_at > now() - interval '1 day') >= 3 then
    perform public.mfa_log(p_user, 'recovery_limited', p_ip);
    return jsonb_build_object('error', 'Too many tries today. Try again tomorrow.');
  end if;
  t1 := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  t2 := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.mfa_recovery_requests (user_id, confirm_hash, cancel_hash, ready_at, expires_at)
  values (p_user, public.mfa_hash('confirm', t1), public.mfa_hash('cancel', t2), now() + p_wait, now() + p_wait + interval '7 days')
  returning * into r;
  perform public.mfa_log(p_user, 'recovery_start', p_ip, jsonb_build_object('request', r.id));
  return jsonb_build_object('confirm', t1, 'cancel', t2, 'ready_at', r.ready_at, 'id', r.id);
end;
$$;

-- The link in the mail. {ok, user_id, id} means "turn 2FA off now"; {wait, ready_at} means too early; else {error}.
-- Bad links: 30 an hour per IP, then refused without logging (the route has no sign-in).
create or replace function public.mfa_bad_links(p_ip text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_ip is not null and (select count(*) from public.security_log where ip = left(p_ip, 64) and event = 'recovery_bad_link' and created_at > now() - interval '1 hour') >= 30;
$$;

create or replace function public.mfa_recovery_confirm(p_token text, p_ip text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.mfa_recovery_requests;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error', 'That link isn’t right. Open it straight from the email.'); end if;
  if public.mfa_bad_links(p_ip) then return jsonb_build_object('error', 'Too many tries. Wait an hour.'); end if;
  select * into r from public.mfa_recovery_requests where confirm_hash = public.mfa_hash('confirm', p_token) for update;
  if not found then
    perform public.mfa_log(null, 'recovery_bad_link', p_ip);
    return jsonb_build_object('error', 'That link isn’t right. Open it straight from the email.');
  end if;
  if r.status = 'cancelled' then return jsonb_build_object('error', 'This reset was cancelled. 2FA is still on.'); end if;
  if r.status = 'done' then return jsonb_build_object('error', 'Already done. 2FA is off, just log in with your password.'); end if;
  if r.expires_at <= now() then return jsonb_build_object('error', 'This link expired. Start again from the 2FA screen.'); end if;
  if r.ready_at > now() then return jsonb_build_object('wait', true, 'ready_at', r.ready_at); end if;
  update public.mfa_recovery_requests set status = 'done', closed_at = now() where id = r.id;
  perform public.mfa_log(r.user_id, 'recovery_confirm', p_ip, jsonb_build_object('request', r.id));
  return jsonb_build_object('ok', true, 'user_id', r.user_id, 'id', r.id, 'created_at', r.created_at);
end;
$$;

-- The route couldn't remove the authenticator after a good confirm: leave the request open to try again.
-- Not when the owner cancelled in the meantime (a cancel while it was 'done' finds nothing pending, but is logged).
create or replace function public.mfa_recovery_reopen(p_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.mfa_recovery_requests r set status = 'pending', closed_at = null
   where r.id = p_id and r.status = 'done'
     and not exists (select 1 from public.security_log l where l.user_id = r.user_id and l.event in ('recovery_cancel', 'recovery_cancel_stale') and l.created_at >= r.closed_at);
$$;

-- Cancel by the mail's cancel link (p_token), or every open one for a signed-in user (p_user, aal2 checked by the route).
create or replace function public.mfa_recovery_cancel(p_token text, p_user uuid, p_ip text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid; st text; n int;
begin
  if p_user is not null then
    uid := p_user;
  else
    if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error', 'That link isn’t right. Open it straight from the email.'); end if;
    if public.mfa_bad_links(p_ip) then return jsonb_build_object('error', 'Too many tries. Wait an hour.'); end if;
    select user_id, status into uid, st from public.mfa_recovery_requests where cancel_hash = public.mfa_hash('cancel', p_token);
    if uid is null then
      perform public.mfa_log(null, 'recovery_bad_link', p_ip);
      return jsonb_build_object('error', 'That link isn’t right. Open it straight from the email.');
    end if;
    -- An old mail's link can't cancel a later request; the log still shows the try.
    if st <> 'pending' then
      perform public.mfa_log(uid, 'recovery_cancel_stale', p_ip);
      return jsonb_build_object('error', case st when 'done' then 'Too late to cancel, this reset was already used. Log in, check 2FA in Settings and change your password.' else 'Already cancelled. 2FA stays on.' end);
    end if;
  end if;
  -- A cancel link stops every open request for the account, not just its own.
  update public.mfa_recovery_requests set status = 'cancelled', closed_at = now() where user_id = uid and status = 'pending';
  get diagnostics n = row_count;
  perform public.mfa_log(uid, 'recovery_cancel', p_ip, jsonb_build_object('cancelled', n, 'by', case when p_user is null then 'email' else 'settings' end));
  return jsonb_build_object('ok', true, 'cancelled', n, 'user_id', uid);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.mfa_hash(text, text)', 'public.mfa_new_code()', 'public.mfa_log(uuid, text, text, jsonb, uuid)',
    'public.mfa_backup_codes_new(uuid, text)', 'public.mfa_recovery_status(uuid)', 'public.mfa_backup_code_use(uuid, text, text, timestamptz)',
    'public.mfa_bad_links(text)',
    'public.mfa_backup_code_unuse(uuid)', 'public.mfa_cleared(uuid)', 'public.mfa_recovery_start(uuid, text, interval)',
    'public.mfa_recovery_confirm(text, text)', 'public.mfa_recovery_reopen(uuid)', 'public.mfa_recovery_cancel(text, uuid, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mfa_recovery', '2FA recovery', 'Backup codes for 2FA, a "Lost your phone?" email reset (24 hour wait) on the 2FA screen, a "Forgot which email?" hint at login, and Remove 2FA for admins in the Mod Center.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
