-- 246: username holds (flag `username_limits`, test). Stops name squatting and "username sniper" tools.
--
-- Name availability stays public (profiles are readable, username_taken() is anon-callable), so we don't hide it.
-- Instead, when you change away from a username, that name is held for you for 7 days. Nobody else can take it in
-- that time ("That username is taken"); you can take it back, which ends your hold. Changing only the letter case
-- (amy -> Amy) holds nothing. username_taken() also says true for a held name (while the flag isn't off), so the
-- sign-up form, /api/signup and the bot API refuse it.
--
-- The daily limit is NOT part of this file: live already has it (made via MCP, no migration file):
--   public.username_changes(user_id, at), trigger profiles_username_limit -> public.username_change_limit(),
--   5 changes a day, staff and case-only changes free. 244 leaves that table, function and trigger alone and
--   doesn't count or log anything itself.
-- Trigger order: Postgres fires BEFORE triggers by name, so profiles_username_limit runs first and
--   profiles_username_limit_holds right after it. A 6th change is refused by the limit before any hold is looked at.
--   If the hold check refuses a name, the whole statement fails, so the limit's log row goes with it: a refused
--   name never uses up a change.
--
-- username_holds: one row per held name (lower-case key), only active while `until > now()`. Only the trigger
--   writes it; clients get no grants at all (RLS on, no policies). Expired rows are just ignored (no cron) and get
--   overwritten the next time that name is held. Hold rows are never removed, only expired (taking your own name
--   back sets until = now()).
--
-- Who it applies to:
--   UPDATE (Settings, PostgREST): only a real user request on their own profile (role authenticated/anon and
--     auth.uid() = the row), never staff (a mod resetting someone's name must not hold it), service_role or SQL
--     editor work, and only when feature_on_for_me('username_limits').
--   INSERT (new accounts; handle_new_user() on auth.users inserts the profile as security definer, so there is no
--     user role to check): holds are enforced only when the flag is in mode 'everyone', whatever the role.
--     handle_new_user() skips held names like it skips used ones (amy -> amy1), so a sign-up never fails over it;
--     the profiles trigger refusing a held name on insert is the backstop. In test mode nothing changes for sign-ups,
--     except that username_taken() already reports held names (holds only exist after a flagged person's change).
--   Test mode: people outside the test can still take a name held by a tester. That is expected until "publish".
--
-- Live definitions copied (pg_get_functiondef, Oct 18): username_taken(text), handle_new_user(). Only the hold
-- checks are added; signatures, security definer, search_path and grants are unchanged.
-- Re-runnable, and safe to paste into the Supabase MCP (nothing it hangs on).

set lock_timeout = '2s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('username_limits', 'Username holds',
  'When you change your username, your old one stays yours for 7 days so nobody can snipe it.',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- holds ----------

create table if not exists public.username_holds (
  name_key text primary key check (name_key = lower(name_key)),
  user_id uuid not null references public.profiles(id) on delete cascade,
  until timestamptz not null
);
create index if not exists username_holds_user_idx on public.username_holds (user_id);
alter table public.username_holds enable row level security;
revoke all on public.username_holds from public, anon, authenticated;

create or replace function public.username_holds_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k_new text := lower(new.username);
  k_old text;
begin
  if tg_op = 'INSERT' then
    -- New accounts: only once the flag is on for everyone (see the header).
    if not exists (select 1 from public.feature_flags where key = 'username_limits' and mode = 'everyone') then return new; end if;
    if exists (select 1 from public.username_holds h where h.name_key = k_new and h.until > now() and h.user_id <> new.id) then
      raise exception 'That username is taken' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  k_old := lower(old.username);
  -- Same name, or only the letter case changed: nothing to hold.
  if k_new is not distinct from k_old then return new; end if;
  -- Real user requests on their own name only, like the other profile guards. Staff aren't limited, and a mod
  -- resetting someone's name (mod_reset_profile) must neither be blocked nor hold the target's old name.
  if coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
     or (select auth.uid()) is distinct from new.id or public.is_staff() then return new; end if;
  if not public.feature_on_for_me('username_limits') then return new; end if;

  -- One change at a time per name, so a name being let go and grabbed at the same moment can't slip through.
  -- Both keys, in a fixed order (two people swapping names can't deadlock).
  perform pg_advisory_xact_lock(k) from (select distinct hashtext('username:' || x) k from unnest(array[k_old, k_new]) x order by 1) s;

  if exists (select 1 from public.username_holds h where h.name_key = k_new and h.until > now() and h.user_id <> new.id) then
    raise exception 'That username is taken' using errcode = 'check_violation';
  end if;

  -- Taking your own held name back ends that hold.
  update public.username_holds set until = now() where name_key = k_new and user_id = new.id and until > now();

  insert into public.username_holds (name_key, user_id, until) values (k_old, new.id, now() + interval '7 days')
    on conflict (name_key) do update set user_id = excluded.user_id, until = excluded.until;
  return new;
end $$;
revoke execute on function public.username_holds_guard() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'profiles_username_limit_holds' and tgrelid = 'public.profiles'::regclass) then
    create trigger profiles_username_limit_holds before insert or update of username on public.profiles
      for each row execute function public.username_holds_guard();
  end if;
end $$;

-- ---------- username_taken: also true for an active hold ----------
-- Live definition (Oct 18) plus the hold line.

CREATE OR REPLACE FUNCTION public.username_taken(name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.profiles where lower(username) = lower(name))
      or (exists (select 1 from public.username_holds h where h.name_key = lower(name) and h.until > now())
          and exists (select 1 from public.feature_flags where key = 'username_limits' and mode <> 'off'));
$function$
;
grant execute on function public.username_taken(text) to anon, authenticated;

-- ---------- handle_new_user: skip held names once the flag is on for everyone ----------
-- Live definition (Oct 18); only `held` and the extra loop condition are new.

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  base text;
  candidate text;
  n int := 0;
  held boolean := exists (select 1 from public.feature_flags where key = 'username_limits' and mode = 'everyone');
begin
  base := regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', ''), '[^A-Za-z0-9_.]', '', 'g');
  if length(base) < 2 then
    base := regexp_replace(split_part(coalesce(new.email, ''), '@', 1), '[^A-Za-z0-9_.]', '', 'g');
  end if;
  if length(base) < 2 then
    base := 'yapper';
  end if;
  base := left(base, 28);
  candidate := base;
  while exists (select 1 from public.profiles where lower(username) = lower(candidate))
     or (held and exists (select 1 from public.username_holds h where h.name_key = lower(candidate) and h.until > now())) loop
    n := n + 1;
    candidate := base || n::text;
  end loop;
  insert into public.profiles (id, username) values (new.id, candidate);
  return new;
end;
$function$
;

reset lock_timeout;
