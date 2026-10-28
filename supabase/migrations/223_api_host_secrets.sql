-- 223: secrets our API host (ops/api) fetches for itself, so nothing has to be typed into the Hetzner console.
--
-- yapper-api-update (root cron on the API box) reads  api_host.secrets where name = 'usage'  with PostgREST's own
-- login (yapper_api, in /opt/yapper-api/.env) while /opt/yapper-api/usage.secret is still the placeholder, saves it
-- there and restarts yapper-api-usage. It is the same value as API_USAGE_SECRET in Vercel (request-limits cron).
--
-- Who can read it: only yapper_api (and postgres/service). Not anon/authenticated/service_role: those are the roles
-- PostgREST switches to for every web request (yapper_api is noinherit and its own grants don't follow the SET ROLE),
-- and api_host isn't in PGRST_DB_SCHEMAS, so no web request can reach it. The value itself is set separately
-- (SQL editor / MCP), never in git.
-- Re-runnable.

create schema if not exists api_host;
revoke all on schema api_host from public, anon, authenticated, service_role;

create table if not exists api_host.secrets (
  name text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
revoke all on api_host.secrets from public, anon, authenticated, service_role;
alter table api_host.secrets enable row level security;

-- yapper_api is made by hand (ops/api/README.md), so skip the grants where it doesn't exist (tests, fresh copies).
-- RLS is on, so yapper_api also needs a policy to see rows (only the one secret it uses).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'yapper_api') then return; end if;
  grant usage on schema api_host to yapper_api;
  grant select on api_host.secrets to yapper_api;
  if not exists (select 1 from pg_policies where schemaname = 'api_host' and tablename = 'secrets' and policyname = 'api host reads usage') then
    create policy "api host reads usage" on api_host.secrets for select to yapper_api using (name = 'usage');
  end if;
end $$;
