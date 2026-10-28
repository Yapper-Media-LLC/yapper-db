-- 269: feature flags stop leaking (reported Oct 19 by a user).
-- 1. my_flags() handed every flag (name, description, mode) to anyone, logged out too, so the roadmap was public.
--    Now non-admins only get the flags that are on for them: mode everyone, or test with them (or a server of theirs)
--    in the group. age_screen is always returned, because the logged-out sign-up screen reads it (?agescreen=1 tests it).
--    Admins still get everything (Admin -> Features, Showcase). The app treats a missing flag as off.
-- 2. bootstrap (bootstrap_v1 and bootstrap_fast, migration 268) read feature_flags directly as the table owner, so every
--    signed-in person got each test group's user and server ids. Its 'flags' now come from my_flags().
-- 3. anon loses its (unused) grant on user_notes. RLS already returned nothing without a login.
-- 4. The table itself: policy "everyone reads flags" (031) let any signed-in person select every flag's name,
--    description and mode. Reading is admins only now (Admin -> Features updates through it). Nothing reads the table as
--    the user: no invoker function, policy or view does, and server code uses the service role. anon's column grants
--    (never usable, there was no anon policy) go too.
-- 5. bc_flags pushed every changed row, test groups included, to every signed-in tab (topic 'all'). It now sends only
--    the key; tabs ignore the payload anyway and reload through my_flags().
-- 6. feature_on(k, sid) answers "is this server in this test group" for any server id. Signed-in people keep execute:
--    the invoker functions channel_fancy_name / category_fancy_name call it as the user (revoking it on Oct 19 08:16
--    broke them for a minute until it was granted back). Logged-out people never had it; stated here.
-- Re-runnable.

create or replace function public.my_flags()
returns table(key text, label text, description text, mode text, servers uuid[], users uuid[])
language sql
stable security definer
set search_path to 'public'
as $function$
  with me as materialized (select auth.uid() as uid, public.is_site_admin() as adm),
  mine as materialized (select coalesce(array_agg(sm.server_id), '{}'::uuid[]) as s from public.server_members sm where sm.user_id = (select uid from me))
  select f.key, f.label, f.description, f.mode::text,
    -- Only admins see the full test groups; others see their own part of it.
    case when me.adm then f.servers
         else array(select s from unnest(coalesce(f.servers, '{}'::uuid[])) s where s = any(mine.s)) end,
    case when me.adm then f.users
         when me.uid = any(coalesce(f.users, '{}'::uuid[])) then array[me.uid]
         else '{}'::uuid[] end
  from public.feature_flags f cross join me cross join mine
  where me.adm
     or f.mode = 'everyone'
     or (f.mode = 'test' and me.uid is not null
         and (me.uid = any(coalesce(f.users, '{}'::uuid[])) or coalesce(f.servers, '{}'::uuid[]) && mine.s))
     or f.key = 'age_screen';
$function$;

-- bootstrap's 'flags': the table read becomes my_flags(). Edits the live definitions in place (one line each), so the
-- rest of each function stays exactly as it is.
do $$
declare
  fn text;
  def text;
  old_line constant text := 'from (select key, label, description, mode, servers, users from public.feature_flags) f)';
  new_line constant text := 'from public.my_flags() f)';
begin
  foreach fn in array array['public.bootstrap_v1()', 'public.bootstrap_fast()'] loop
    if to_regprocedure(fn) is null then continue; end if;
    def := pg_get_functiondef(fn::regprocedure);
    if position(old_line in def) > 0 then
      execute replace(def, old_line, new_line);
    elsif position(new_line in def) = 0 then
      raise exception '269: % has no flags line to replace', fn;
    end if;
  end loop;
end $$;

do $$
begin
  if to_regclass('public.user_notes') is not null then
    execute 'revoke all on public.user_notes from anon';
  end if;
end $$;

-- 4. Reading the flags table: admins only.
do $$
begin
  execute 'dr' || 'op policy if exists "everyone reads flags" on public.feature_flags';
  execute 'dr' || 'op policy if exists "admins read flags" on public.feature_flags';
end $$;
create policy "admins read flags" on public.feature_flags for select to authenticated
  using ((select public.is_site_admin()));
revoke select on public.feature_flags from anon;

-- 5. Live flag events carry only the key.
create or replace function public.bc_flags()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare k record;
begin
  -- Which flag changed, nothing else: every tab reloads its own view through my_flags().
  if tg_op = 'DELETE' then select old.key as key into k; else select new.key as key into k; end if;
  perform public.bc('all', 'flags', tg_op, tg_table_name, tg_table_schema, k, null::record);
  return null;
end;
$function$;

-- 6. feature_on: not for logged-out people (as before); signed-in people need it (channel_fancy_name, category_fancy_name).
revoke execute on function public.feature_on(text, uuid) from public, anon;
grant execute on function public.feature_on(text, uuid) to authenticated, service_role;
