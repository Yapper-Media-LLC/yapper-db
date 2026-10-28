-- 600: secrets for the app host (ops/app, bots.yapper.website) that can't be typed into its console.
-- The box already has the service role key; at container start ops/app/start.mjs calls app_host_secrets() with it
-- and adds whatever is missing from its environment (env values always win). Nobody else can read or list them:
-- the schema isn't exposed by PostgREST, anon/authenticated have no rights on it, and only service_role may run
-- the function. Antic adds or changes rows in the SQL editor (insert ... on conflict do update), then the box picks
-- them up on its next restart (yapper-app-update --force, or the next release). start.mjs only takes LiveKit,
-- Anthropic and model names from here. The SQL editor keeps query history: delete the insert from it afterwards.
-- Re-runnable.

create schema if not exists app_host;
revoke all on schema app_host from public, anon, authenticated, service_role;

create table if not exists app_host.secrets (
  name text primary key check (name ~ '^[A-Z][A-Z0-9_]{1,63}$'),
  value text not null check (length(value) between 1 and 4096),
  updated_at timestamptz not null default now()
);
alter table app_host.secrets enable row level security;
revoke all on app_host.secrets from public, anon, authenticated, service_role;

create or replace function public.app_host_secrets()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return coalesce((select jsonb_object_agg(s.name, s.value) from app_host.secrets s), '{}'::jsonb);
end;
$$;

revoke all on function public.app_host_secrets() from public, anon, authenticated;
grant execute on function public.app_host_secrets() to service_role;
