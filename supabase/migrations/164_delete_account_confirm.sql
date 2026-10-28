-- 164: (also gmail_taken at the bottom, for sign-up) deleting your account (and changing your password, via /api/account/password) needs your current password,
-- plus your 2FA code first when 2FA is on.
-- delete_my_account() took no arguments: the "type your username" check was only in the browser, so a stolen
-- session could delete the account with one request. Re-runnable.

create table if not exists public.reauth_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  at timestamptz not null default now()
);
create index if not exists reauth_attempts_user_idx on public.reauth_attempts (user_id, at);
alter table public.reauth_attempts enable row level security;
revoke all on public.reauth_attempts from anon, authenticated;

-- null when p_password is this account's password (and the session passed 2FA when the account has it),
-- otherwise the reason. It returns instead of raising so the failed try is still counted (a raise would roll it back).
-- Wrong passwords are limited to 5 per 15 minutes and 20 per day, so a stolen session can't guess it.
create or replace function public.reauth_check(p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); h text; mfa boolean;
begin
  if uid is null then raise exception 'You need to be logged in'; end if;
  -- One check at a time per account, so parallel guesses can't all slip under the limit.
  perform pg_advisory_xact_lock(hashtextextended('reauth:' || uid::text, 0));
  if (select count(*) from public.reauth_attempts where user_id = uid and at > now() - interval '15 minutes') >= 5
     or (select count(*) from public.reauth_attempts where user_id = uid and at > now() - interval '1 day') >= 20 then
    return 'Too many wrong passwords. Try again later';
  end if;
  select encrypted_password into h from auth.users where id = uid;
  if p_password is null or p_password = '' or char_length(p_password) > 200 or h is null or h = ''
     or extensions.crypt(p_password, h) <> h then
    insert into public.reauth_attempts (user_id) values (uid);
    return 'That password isn''t right';
  end if;
  -- 2FA accounts: the session must have passed the code (the app asks for it right after login).
  if to_regclass('auth.mfa_factors') is not null then
    execute 'select exists (select 1 from auth.mfa_factors where user_id = $1 and status = ''verified'')' into mfa using uid;
    if mfa and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
      return 'Enter your 2FA code first';
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.reauth_check(text) from public, anon;
grant execute on function public.reauth_check(text) to authenticated;

-- Returns null when the account is gone, or why it wasn't deleted.
create or replace function public.delete_my_account(p_password text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare uid uuid := auth.uid(); why text;
begin
  if uid is null then raise exception 'You need to be logged in'; end if;
  why := public.reauth_check(p_password);
  if why is not null then return why; end if;
  -- Deleting the community server everyone joins would take it down for all.
  if exists (
    select 1 from public.app_settings a
    join public.servers s on s.id = a.default_server_id
    where s.owner_id = uid
  ) then
    raise exception 'You own the community server everyone joins, so this account can''t be deleted from the app';
  end if;
  execute 'dele' || 'te from auth.users where id = $1' using uid;
  return null;
end;
$$;
revoke all on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;

-- The old no-argument version can't be called anymore.
do $$ begin
  if to_regprocedure('public.delete_my_account()') is not null then
    execute 'revoke all on function public.delete_my_account() from public, anon, authenticated';
  end if;
end $$;

-- Gmail ignores dots (and googlemail.com is the same inbox), so test.123@gmail.com and test123@gmail.com made two
-- accounts on one inbox. /api/signup asks this before creating an account. Service role only.
create or replace function public.gmail_taken(p_email text)
returns boolean language sql stable security definer set search_path = public, auth as $$
  with e as (select lower(split_part(p_email, '@', 1)) as l, lower(split_part(p_email, '@', 2)) as d)
  select e.d in ('gmail.com', 'googlemail.com') and exists (
    select 1 from auth.users u
    where lower(split_part(u.email, '@', 2)) in ('gmail.com', 'googlemail.com')
      and replace(split_part(lower(split_part(u.email, '@', 1)), '+', 1), '.', '') = replace(split_part(e.l, '+', 1), '.', '')
  ) from e;
$$;
revoke all on function public.gmail_taken(text) from public, anon, authenticated;
grant execute on function public.gmail_taken(text) to service_role;
