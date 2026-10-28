-- 217: emergency switch to pause new sign-ups during a raid / mass bot sign-up wave. Re-runnable.
--
-- Yapper admins set a pause for a number of minutes (Mod Center > Features), so it can't be forgotten on: it ends
-- by itself. While it's on:
--   * /api/signup answers "Sign-ups are paused" before doing anything else (friendly message, no captcha spent);
--   * a BEFORE INSERT trigger on auth.users refuses every other way to create an account (direct calls to Supabase
--     Auth with the public key, OAuth). Supabase shows those callers a generic "Database error saving new user".
-- Bot and webhook accounts made by our own server code are never paused: it notes the random email in
-- pending_bot_emails right before admin.createUser, and only those pass. (The email alone can't be trusted: anyone can
-- ask Supabase Auth for an account at @bots.yapper.website.)
-- Logging in, chatting, everything else is untouched.

alter table public.app_settings add column if not exists signups_paused_until timestamptz;

-- Bot / webhook account emails our server is about to create (service role only; RLS on, no policies).
create table if not exists public.pending_bot_emails (
  email text primary key,
  created_at timestamptz not null default now()
);
alter table public.pending_bot_emails enable row level security;
revoke all on public.pending_bot_emails from anon, authenticated;

-- When the pause ends, or null when sign-ups are open. Public: the sign-up screen and /api/signup ask.
create or replace function public.signups_paused()
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select signups_paused_until from public.app_settings where signups_paused_until > now() limit 1;
$$;
revoke all on function public.signups_paused() from public;
grant execute on function public.signups_paused() to anon, authenticated, service_role;

-- Yapper admins only. minutes = 0 reopens sign-ups; otherwise 1 minute to 7 days.
create or replace function public.set_signups_paused(minutes int)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare until timestamptz;
begin
  if not public.is_site_admin() then raise exception 'Only Yapper admins can pause sign-ups'; end if;
  if minutes is null or minutes < 0 or minutes > 10080 then raise exception 'Pick 0 (open) to 10080 minutes'; end if;
  until := case when minutes = 0 then null else now() + make_interval(mins => minutes) end;
  -- One row (id = true); the WHERE also keeps Supabase's safeupdate guard happy.
  update public.app_settings set signups_paused_until = until where id returning signups_paused_until into until;
  if not found then raise exception 'app_settings row missing'; end if;
  return until;
end $$;
revoke all on function public.set_signups_paused(int) from public, anon;
grant execute on function public.set_signups_paused(int) to authenticated;

-- The backstop: no account is created while paused, whichever way the request came in.
create or replace function public.signup_pause_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.app_settings where signups_paused_until > now()) then
    -- Our own bot / webhook accounts (noted by the server a moment ago) still get made.
    if exists (select 1 from public.pending_bot_emails p
                where p.email = lower(new.email) and p.created_at > now() - interval '10 minutes') then
      return new;
    end if;
    raise exception 'Sign-ups are paused for a bit. Try again later.' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.signup_pause_guard() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'signup_pause_guard' and tgrelid = 'auth.users'::regclass) then
    execute 'create trigger signup_pause_guard before insert on auth.users for each row execute function public.signup_pause_guard()';
  end if;
end $$;
