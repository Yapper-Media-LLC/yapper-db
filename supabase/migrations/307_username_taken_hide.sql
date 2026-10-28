-- 307: the old username_taken() leaves the API schema (Oct 20). The app calls srv_username_taken (306) since PR #44.
-- Scripts kept calling rpc/username_taken ~1.5M times an hour; every refusal reached Postgres. In a schema PostgREST
-- doesn't expose, the call gets a 404 from PostgREST's schema cache and the database never sees it. Nothing in the
-- database calls the old function (checked). Moved, not deleted, so it's easy to bring back. Re-runnable.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'username_taken') then
    alter function public.username_taken(text) set schema private;
  end if;
end $$;
