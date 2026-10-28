-- 335: take away table privileges nobody can use (Oct 21). Supabase grants anon and authenticated every privilege on
-- every public table by default; row level security is what actually decides. This removes the ones no policy lets
-- through, so they stop being a second way in if a policy or function ever has a mistake:
--   * anon (logged out): no insert, update or delete anywhere. No public table has a write policy for anon or public,
--     so these writes already fail today.
--   * authenticated: insert / update / delete only where a permissive policy for authenticated (or public) covers that
--     command. 50+ tables had write grants with no write policy (site_admins, site_bans, mod_log, user_warnings,
--     server_plus, billing_customers, staff_reauth...), so those writes already fail today too.
--   * both: no truncate, trigger or references. PostgREST never uses them, and truncate skips row level security.
-- Security definer functions run as their owner and the service role is untouched, so nothing that works today
-- changes. New tables still get Supabase's default grants; a later run of this file tidies them the same way.
-- Update stays wherever inserts are allowed: insert ... on conflict do update (upserts, e.g. server_mutes) needs the
-- update privilege up front even when it only inserts, and the conflict path stays blocked by row level security as
-- before. Revoking a table privilege also drops the matching column privileges, so update is only revoked where no
-- update or insert policy exists (profiles keeps its column update grants). Re-runnable.

do $$
declare
  r record;
  c text;
begin
  for r in
    select c2.relname from pg_class c2 join pg_namespace n on n.oid = c2.relnamespace
    where n.nspname = 'public' and c2.relkind in ('r', 'p')
  loop
    execute format('revoke insert, update, delete, truncate, trigger, references on public.%I from anon', r.relname);
    execute format('revoke truncate, trigger, references on public.%I from authenticated', r.relname);
    foreach c in array array['INSERT', 'UPDATE', 'DELETE'] loop
      if not exists (
        select 1 from pg_policies p
        where p.schemaname = 'public' and p.tablename = r.relname and p.permissive = 'PERMISSIVE'
          and (p.cmd in (c, 'ALL') or (c = 'UPDATE' and p.cmd = 'INSERT'))
          and p.roles && array['authenticated', 'public']::name[]
      ) then
        execute format('revoke %s on public.%I from authenticated', c, r.relname);
      end if;
    end loop;
  end loop;
end $$;
