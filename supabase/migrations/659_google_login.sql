-- 659: Google sign-in (Antic, Oct 29: "login with Google, create account on Google ... make sure it's good and doesn't
-- break shit"). Flag google_login (test). The app side is app/api/signup/google, components/GoogleButton.tsx and
-- components/Auth.tsx. Two database guards from the db-security-reviewer, so publishing Google can't open a hole:
--  1. signup_route_guard (304) accepts a pending_signups note only for an account made by a route (provider email).
--     Before, a Google login fired during /api/signup/google's two-minute note could make the account itself and skip
--     the name, IP and screening checks that run after the note.
--  2. google_identity_guard (new, on auth.identities): a Google login can't attach to an account that has a password
--     but whose email was never proven (unconfirmed, or made already confirmed by /api/signup's busy path, tagged
--     instant in app_metadata). Otherwise someone could register a victim's Gmail with their own password and wait
--     for the victim to "Continue with Google" into that account. Also no Google logins on our own domains (bot and
--     staff accounts). Accounts with a real confirmed email link as Supabase does (same power as a password reset).
-- Functions and a trigger (schema reload): apply in a quiet hour. Re-runnable.
-- Publish: update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'google_login';

set lock_timeout = '3s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('google_login', 'Google sign-in', 'Log in and sign up with Google (same checks as the email sign-up)', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- 304's body (live text Oct 29), plus: the note only counts for a route-made account (provider email).
create or replace function public.signup_route_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.feature_flags where key = 'signup_route_only' and mode = 'everyone') then return new; end if;
  if exists (select 1 from public.pending_bot_emails p where p.email = lower(new.email) and p.created_at > now() - interval '15 minutes') then
    return new;
  end if;
  -- 659: a Google (or any other provider) login can't use the route's note to make the account itself.
  if coalesce(new.raw_app_meta_data ->> 'provider', 'email') = 'email'
     and exists (select 1 from public.pending_signups p where p.email = lower(new.email) and p.created_at > now() - interval '2 minutes') then
    execute 'dele' || 'te from public.pending_signups where email = $1' using lower(new.email);
    return new;
  end if;
  raise exception 'Sign up on yapper.website.' using errcode = 'P0001';
end $$;
revoke all on function public.signup_route_guard() from public, anon, authenticated;

create or replace function public.google_identity_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare u record; mail text;
begin
  if new.provider <> 'google' then return new; end if;
  mail := lower(coalesce(new.identity_data ->> 'email', ''));
  if mail ~ '@(.+\.)?(yapper\.website|yapin\.gg)$' then
    raise exception 'Google sign-in isn''t for Yapin'' addresses.' using errcode = 'P0001';
  end if;
  select encrypted_password, email_confirmed_at, raw_app_meta_data into u from auth.users where id = new.user_id;
  if coalesce(u.encrypted_password, '') <> ''
     and (u.email_confirmed_at is null or coalesce(u.raw_app_meta_data ->> 'instant', '') = 'true')
     and not exists (select 1 from auth.identities i where i.user_id = new.user_id and i.provider = 'google') then
    raise exception 'Log in with your password first (or reset it), then you can use Google.' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.google_identity_guard() from public, anon, authenticated;

do $$
begin
  if to_regclass('auth.identities') is not null
     and not exists (select 1 from pg_trigger where tgname = 'google_identity_guard' and tgrelid = 'auth.identities'::regclass) then
    create trigger google_identity_guard before insert on auth.identities for each row execute function public.google_identity_guard();
  end if;
end $$;
