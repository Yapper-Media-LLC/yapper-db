-- STAND-INS FOR SUPABASE-PROVIDED PIECES. Nothing in this file is Yapper's own code.
--
-- On the live database these come from Supabase: the API roles, the auth schema (GoTrue's tables and the
-- auth.uid()/auth.role()/auth.jwt() helpers), Storage's tables, Realtime's messages table, Vault, and the pg_net
-- extension. A vanilla Postgres has none of them, so the schema dump (schema/*.sql) would not restore without them.
--
-- What is kept faithful, because the policies and our functions depend on it:
--   - the role names and their RLS behaviour (service_role bypasses RLS, anon/authenticated do not)
--   - auth.uid(), auth.role(), auth.jwt() read the JWT claims exactly the way Supabase's versions do
--     (request.jwt.claims as JSON, falling back to the older request.jwt.claim.sub setting)
--   - the column lists of auth.users, auth.identities, auth.mfa_factors, storage.objects and storage.buckets,
--     copied from the live tables (types and not-null), so our triggers and functions that read them work
-- What is simplified: no GoTrue/Storage logic, no Supabase-internal triggers, no indexes, Realtime's messages
-- table is a plain table (live it is partitioned by day), pg_net only records the requests it is asked to send,
-- Vault is an empty table.
--
-- Our own functions (is_site_mod, is_staff, server_perm, every policy...) are NOT in here. They come from the
-- live dump, unmodified.

set client_min_messages = warning;

-- ----- roles (cluster-wide, so guarded) -----
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
do $$ begin create role authenticator login noinherit; exception when duplicate_object then null; end $$;
grant anon, authenticated, service_role to authenticator;

-- Same search_path as the live postgres role.
do $$ begin execute format('alter database %I set search_path = "$user", public, extensions', current_database()); end $$;
set search_path = "$user", public, extensions;

create schema if not exists extensions;
grant usage on schema extensions to public;
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists realtime;
create schema if not exists vault;
create schema if not exists net;
grant usage on schema auth, storage, realtime to anon, authenticated, service_role;

-- ----- auth -----
create type auth.factor_type as enum ('totp', 'webauthn', 'phone');
create type auth.factor_status as enum ('unverified', 'verified');
create type auth.aal_level as enum ('aal1', 'aal2', 'aal3');

create table auth.users (
  instance_id uuid,
  id uuid not null primary key default gen_random_uuid(),
  aud varchar(255) default 'authenticated',
  role varchar(255) default 'authenticated',
  email varchar(255),
  encrypted_password varchar(255),
  email_confirmed_at timestamptz,
  invited_at timestamptz,
  confirmation_token varchar(255),
  confirmation_sent_at timestamptz,
  recovery_token varchar(255),
  recovery_sent_at timestamptz,
  email_change_token_new varchar(255),
  email_change varchar(255),
  email_change_sent_at timestamptz,
  last_sign_in_at timestamptz,
  raw_app_meta_data jsonb default '{}',
  raw_user_meta_data jsonb default '{}',
  is_super_admin boolean,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  phone text,
  phone_confirmed_at timestamptz,
  phone_change text,
  phone_change_token varchar(255),
  phone_change_sent_at timestamptz,
  confirmed_at timestamptz,
  email_change_token_current varchar(255),
  email_change_confirm_status smallint,
  banned_until timestamptz,
  reauthentication_token varchar(255),
  reauthentication_sent_at timestamptz,
  is_sso_user boolean not null default false,
  deleted_at timestamptz,
  is_anonymous boolean not null default false
);

create table auth.identities (
  provider_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  identity_data jsonb not null,
  provider text not null,
  last_sign_in_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  email text,
  id uuid not null primary key default gen_random_uuid()
);

create table auth.mfa_factors (
  id uuid not null primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  friendly_name text,
  factor_type auth.factor_type not null,
  status auth.factor_status not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  secret text,
  phone text,
  last_challenged_at timestamptz,
  web_authn_credential jsonb,
  web_authn_aaguid uuid,
  last_webauthn_challenge_data jsonb
);

-- Supabase's definitions: PostgREST puts the verified JWT payload in request.jwt.claims.
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text
$$;
create or replace function auth.email() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.email', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'))::text
$$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''),
                  nullif(current_setting('request.jwt.claims', true), ''))::jsonb
$$;
grant execute on function auth.uid(), auth.role(), auth.email(), auth.jwt() to anon, authenticated, service_role;

-- ----- storage -----
create type storage.buckettype as enum ('STANDARD', 'ANALYTICS', 'VECTOR');
create table storage.buckets (
  id text not null primary key,
  name text not null,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  public boolean default false,
  avif_autodetection boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  owner_id text,
  type storage.buckettype not null default 'STANDARD',
  versioning_status text not null default 'disabled',
  lifecycle_configuration jsonb,
  lifecycle_configuration_generation uuid
);
create table storage.objects (
  id uuid not null primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  version text,
  owner_id text,
  user_metadata jsonb,
  archived_at timestamptz,
  is_delete_marker boolean not null default false,
  is_versioned boolean not null default false
);
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;
-- Storage's helpers (same behaviour as Supabase's).
create or replace function storage.foldername(name text) returns text[] language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end $$;
create or replace function storage.filename(name text) returns text language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[array_length(_parts, 1)];
end $$;
create or replace function storage.extension(name text) returns text language plpgsql immutable as $$
declare _parts text[]; _filename text;
begin
  select string_to_array(name, '/') into _parts;
  select _parts[array_length(_parts, 1)] into _filename;
  return reverse(split_part(reverse(_filename), '.', 1));
end $$;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;

-- ----- realtime (Supabase Realtime's broadcast authorization table) -----
create table realtime.messages (
  topic text not null,
  extension text not null,
  payload jsonb,
  event text,
  private boolean default false,
  updated_at timestamp not null default now(),
  inserted_at timestamp not null default now(),
  id uuid not null default gen_random_uuid(),
  primary key (id, inserted_at)
);
alter table realtime.messages enable row level security;
grant select, insert, update, delete on realtime.messages to anon, authenticated, service_role;
create or replace function realtime.topic() returns text language sql stable as $$
  select nullif(current_setting('realtime.topic', true), '')::text
$$;
grant execute on function realtime.topic() to anon, authenticated, service_role;
create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
language sql as $$ insert into realtime.messages (payload, event, topic, private, extension) values (payload, event, topic, private, 'broadcast') $$;
create or replace function realtime.broadcast_changes(topic_name text, event_name text, operation text, table_name text,
  table_schema text, new record, old record, level text default 'ROW') returns void language plpgsql as $$
begin
  perform realtime.send(jsonb_build_object('operation', operation, 'table', table_name, 'schema', table_schema), event_name, topic_name, true);
end $$;

-- ----- vault (empty: no secret values exist in this test database) -----
create table vault.decrypted_secrets (
  id uuid primary key default gen_random_uuid(),
  name text unique,
  description text,
  secret text,
  decrypted_secret text,
  key_id uuid,
  nonce bytea,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ----- pg_net: records requests instead of sending them -----
create table net.http_request_queue (
  id bigserial primary key,
  method text not null,
  url text not null,
  headers jsonb,
  body jsonb,
  timeout_milliseconds int,
  created_at timestamptz not null default now()
);
create table net._http_response (
  id bigint,
  status_code int,
  content_type text,
  headers jsonb,
  content text,
  timed_out boolean,
  error_msg text,
  created timestamptz not null default now()
);
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds int default 5000) returns bigint
language sql as $$
  insert into net.http_request_queue (method, url, headers, body, timeout_milliseconds)
  values ('POST', url, headers, body, timeout_milliseconds) returning id
$$;
create or replace function net.http_get(url text, params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb,
  timeout_milliseconds int default 5000) returns bigint
language sql as $$
  insert into net.http_request_queue (method, url, headers, timeout_milliseconds)
  values ('GET', url, headers, timeout_milliseconds) returning id
$$;

