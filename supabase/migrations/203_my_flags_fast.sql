-- 203: my_flags() was ~30 ms per call (6,500 calls in 11 min on Oct 17 evening, about 0.3 of a core): it ran
-- is_site_admin() (with its staff MFA check) twice per flag row and is_server_member() per test server per flag.
-- Now the caller's admin status and server list are worked out once. Same output (checked live against the old
-- function for an admin, a 150-server account and the test account: 0 differing rows), 5-13x faster. Re-runnable.
create or replace function public.my_flags()
returns table(key text, label text, description text, mode text, servers uuid[], users uuid[])
language sql
stable
security definer
set search_path to 'public'
as $function$
  with me as materialized (select auth.uid() as uid, public.is_site_admin() as adm),
  mine as materialized (select coalesce(array_agg(sm.server_id), '{}'::uuid[]) as s from public.server_members sm where sm.user_id = (select uid from me))
  select f.key, f.label, f.description, f.mode::text,
    -- Everyone sees which features exist; only admins see the full test groups.
    case when me.adm then f.servers
         else array(select s from unnest(coalesce(f.servers, '{}'::uuid[])) s where s = any(mine.s)) end,
    case when me.adm then f.users
         when me.uid = any(coalesce(f.users, '{}'::uuid[])) then array[me.uid]
         else '{}'::uuid[] end
  from public.feature_flags f cross join me cross join mine;
$function$;
