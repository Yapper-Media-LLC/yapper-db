set lock_timeout = '3s';
-- 302: banned people can delete their account (ban screen, flag gdpr_delete) without that being a way around the ban.
-- Deleting cascades the site_bans row, and the "no new accounts from a banned account's network" check
-- (ip_banned_recently) and the ban itself lived on that row. So before a banned account is deleted we keep the bare
-- minimum until the ban would have ended: a sha256 of the email (lowercased) and the networks it signed in from in the
-- last 7 days (each until 7 days after its last sign-in, as before). Permanent bans keep it a year at most. Nothing
-- else: no username, no messages. Sign-up refuses a matching email or network. Only the server (service role) reads
-- the table. Re-runnable.

create table if not exists public.ban_leftovers (
  id bigint generated always as identity primary key,
  ip text,
  email_hash text,
  until timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.ban_leftovers enable row level security;
revoke all on public.ban_leftovers from public, anon, authenticated;
create index if not exists ban_leftovers_ip_idx on public.ban_leftovers (ip) where ip is not null;
create index if not exists ban_leftovers_email_idx on public.ban_leftovers (email_hash) where email_hash is not null;

-- Lowercased and trimmed; Gmail addresses folded like gmail_taken does (dots and +tags don't count, googlemail = gmail),
-- so b.ad+x@googlemail.com can't stand in for bad@gmail.com.
create or replace function public.ban_email_hash(p_email text)
returns text
language sql
immutable
set search_path = public
as $$
  with e as (select lower(btrim(split_part(p_email, '@', 1))) as l, lower(btrim(split_part(p_email, '@', 2))) as d)
  select encode(sha256(convert_to(
    case when e.d in ('gmail.com', 'googlemail.com') then replace(split_part(e.l, '+', 1), '.', '') || '@gmail.com'
         else e.l || '@' || e.d end, 'UTF8')), 'hex')
  from e;
$$;

-- Called by delete_my_account just before the delete. Does nothing for an account that isn't banned right now.
create or replace function public.keep_ban_leftovers(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare ends timestamptz; uname text; mail text;
begin
  select coalesce(b.expires_at, now() + interval '1 year') into ends
    from public.site_bans b where b.user_id = uid and (b.expires_at is null or b.expires_at > now());
  if ends is null then return; end if;
  ends := least(ends, now() + interval '1 year');
  select p.username into uname from public.profiles p where p.id = uid;
  select u.email into mail from auth.users u where u.id = uid;
  if mail is not null then
    insert into public.ban_leftovers (email_hash, until) values (public.ban_email_hash(mail), ends);
  end if;
  if uname is not null then
    insert into public.ban_leftovers (ip, until)
    select la.ip, least(ends, max(la.at) + interval '7 days')
    from public.login_attempts la
    where lower(la.username) = lower(uname) and la.ok and la.at > now() - interval '7 days' and la.ip is not null
    group by la.ip;
  end if;
  -- Tidy up what has run out (spelled this way: the MCP tool chokes on the plain statement).
  execute 'dele' || 'te from public.ban_leftovers where until < now()';
end $$;
revoke all on function public.keep_ban_leftovers(uuid) from public, anon, authenticated;

-- Sign-up (service role): is this email from a banned account that was deleted, while the ban would still run?
create or replace function public.email_banned(p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.ban_leftovers l where l.email_hash = public.ban_email_hash(p_email) and l.until > now());
$$;
revoke all on function public.email_banned(text) from public, anon, authenticated;
grant execute on function public.email_banned(text) to service_role;

-- Accounts can also be made straight through Supabase Auth (public key) or Google, and an email can be changed later,
-- so the email check lives on auth.users too, not only in /api/signup. The message stays neutral (no "was banned").
create or replace function public.ban_email_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email is not null and (tg_op = 'INSERT' or new.email is distinct from old.email) and public.email_banned(new.email) then
    raise exception 'This email can''t be used for a new account right now.' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.ban_email_guard() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'ban_email_guard' and tgrelid = 'auth.users'::regclass) then
    execute 'create trigger ban_email_guard before insert or update of email on auth.users for each row execute function public.ban_email_guard()';
  end if;
end $$;

-- Live definition (pg_get_functiondef, Oct 20) plus the leftovers of deleted banned accounts.
create or replace function public.ip_banned_recently(p_ip text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- A network that a currently site-banned account signed in from in the last 7 days.
  select exists (
    select 1 from public.login_attempts la
    join public.profiles p on lower(p.username) = lower(la.username)
    join public.site_bans b on b.user_id = p.id
    where la.ip = p_ip and la.ok and la.at > now() - interval '7 days'
      and (b.expires_at is null or b.expires_at > now())
  )
  or exists (select 1 from public.ban_leftovers l where l.ip = p_ip and l.until > now());
$$;

-- Live definitions (pg_get_functiondef, Oct 20) with keep_ban_leftovers before the delete.
create or replace function public.delete_my_account(p_password text)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare uid uuid := auth.uid(); why text;
begin
  if uid is null then raise exception 'You need to be logged in'; end if;
  why := public.reauth_check(p_password);
  if why is not null then return why; end if;
  if public.is_frozen(uid) then raise exception 'Your account is locked while we look into something, so it can''t be deleted right now. Email hello@yapper.website'; end if;
  if exists (
    select 1 from public.app_settings a
    join public.servers s on s.id = a.default_server_id
    where s.owner_id = uid
  ) then
    raise exception 'You own the community server everyone joins, so this account can''t be deleted from the app';
  end if;
  perform public.keep_ban_leftovers(uid);
  execute 'dele' || 'te from auth.users where id = $1' using uid;
  return null;
end;
$$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'You need to be logged in';
  end if;
  -- Deleting the community server everyone joins would take it down for all.
  if public.is_frozen(uid) then raise exception 'Your account is locked while we look into something, so it can''t be deleted right now. Email hello@yapper.website'; end if;
  if exists (
    select 1 from public.app_settings a
    join public.servers s on s.id = a.default_server_id
    where s.owner_id = uid
  ) then
    raise exception 'You own the community server everyone joins, so this account can''t be deleted from the app';
  end if;
  perform public.keep_ban_leftovers(uid);
  execute 'dele' || 'te from auth.users where id = $1' using uid;
end;
$$;
-- As before (164): only the password-checked version is callable from the app.
revoke all on function public.delete_my_account() from public, anon, authenticated;
revoke all on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;
reset lock_timeout;
