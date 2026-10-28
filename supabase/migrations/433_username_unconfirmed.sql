-- A username stayed taken by a sign-up that never confirmed its email (a typo in the address, a lost email), so the
-- person couldn't sign up again with their own name (bug reports, Oct 2026; staff note "on the list").
-- Live on Oct 23: 8,440 profiles belong to never-confirmed sign-ups; none has ever signed in or sent a message.
--
-- Now a name held by such an account (unconfirmed, never signed in, made over an hour ago, not a bot) counts as free:
-- /api/signup's check (srv_username_taken) lets it through, and handle_new_user gives the stale account a placeholder
-- name (user_<12 hex>) right before the new account takes it. If the old sign-up is confirmed later, it can pick a
-- name in Settings. Nothing changes for existing accounts until someone signs up with that exact name.
-- Safe to apply any time.

create or replace function public.username_stale_hold(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from auth.users u
    where u.id = uid and u.email_confirmed_at is null and u.last_sign_in_at is null
      and u.created_at < now() - interval '1 hour')
    and not exists (select 1 from public.bots b where b.id = uid)
    and not exists (select 1 from public.bot_accounts a where a.user_id = uid);
$$;
revoke all on function public.username_stale_hold(uuid) from public, anon, authenticated;

create or replace function public.srv_username_taken(name text)
returns boolean language sql stable security definer set search_path to 'public' as $function$
  select exists (select 1 from public.profiles p where lower(p.username) = lower(name) and not public.username_stale_hold(p.id))
      or (exists (select 1 from public.username_holds h where h.name_key = lower(name) and h.until > now())
          and exists (select 1 from public.feature_flags where key = 'username_limits' and mode <> 'off'));
$function$;
revoke all on function public.srv_username_taken(text) from public, anon, authenticated;

-- handle_new_user (live version not in the repo): free the name from a stale sign-up before picking one.
do $$
declare
  f text;
  old_part text := '  candidate := base;';
  new_part text := E'  candidate := base;\n'
    || E'  -- 433: a name held by a sign-up that never confirmed (over an hour ago) goes to this account instead.\n'
    || E'  begin\n'
    || E'    update public.profiles p set username = ''user_'' || left(replace(p.id::text, ''-'', ''''), 12)\n'
    || E'     where lower(p.username) = lower(base) and p.id <> new.id and public.username_stale_hold(p.id);\n'
    || E'  exception when others then null;\n'
    || E'  end;';
begin
  select pg_get_functiondef('public.handle_new_user()'::regprocedure) into f;
  if position('-- 433: a name held' in f) > 0 then return; end if; -- already patched
  if position(old_part in f) = 0 then raise exception '433: handle_new_user changed, patch the stale-name release by hand'; end if;
  execute replace(f, old_part, new_part);
end $$;
