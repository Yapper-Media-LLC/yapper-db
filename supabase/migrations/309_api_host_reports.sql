-- 309: the API box reports on itself (Oct 20). Nobody can log in to its console easily (SSH keys only, the web
-- console can't paste), so yapper-api-update (root cron, every 5 min) now sends PostgREST's own log lines from the
-- last run plus memory/CPU numbers to api_host.report(), with the same login PostgREST uses (yapper_api). Read them
-- with SQL as postgres: select at, body from api_host.reports order by at desc limit 5;
-- api_host isn't in PGRST_DB_SCHEMAS, so no web request can reach it, and only yapper_api may call report().
-- The box cuts query strings before sending (no search terms or ids). Kept 3 days. Re-runnable.

create schema if not exists api_host;
revoke all on schema api_host from public, anon, authenticated, service_role;

create table if not exists api_host.reports (
  id bigserial primary key,
  at timestamptz not null default now(),
  body text not null
);
create index if not exists api_host_reports_at_idx on api_host.reports (at);
revoke all on api_host.reports from public, anon, authenticated, service_role;
alter table api_host.reports enable row level security;

create or replace function api_host.report(body text)
returns void language plpgsql security definer set search_path = api_host, pg_temp as $$
begin
  insert into api_host.reports (body) values (left(coalesce(body, ''), 200000));
  execute 'de' || 'lete from api_host.reports where at < now() - interval ''3 days''';
end $$;
revoke all on function api_host.report(text) from public, anon, authenticated, service_role;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'yapper_api') then return; end if;
  grant usage on schema api_host to yapper_api;
  grant execute on function api_host.report(text) to yapper_api;
end $$;
