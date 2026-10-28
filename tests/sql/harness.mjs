// Runs the Supabase migrations inside PGlite (real Postgres in WASM) with
// small stand-ins for Supabase's auth/storage schemas, so the SQL and the
// row-level-security rules can be tested without a Supabase project.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, '..', '..', 'supabase', 'migrations');

const SUPABASE_STUBS = `
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb not null default '{}'
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
create schema storage;
create table storage.buckets (
  id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid default auth.uid()
);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language plpgsql as $$
declare parts text[] := string_to_array(name, '/');
begin
  return parts[1:array_length(parts,1)-1];
end $$;
create publication supabase_realtime;
grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated;
grant select on storage.buckets to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
`;

export function migrationFiles(upTo = Infinity) {
  return readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .filter((f) => parseInt(f, 10) <= upTo);
}

export async function setup(upTo = Infinity) {
  const db = new PGlite();
  await db.exec(SUPABASE_STUBS);
  for (const f of migrationFiles(upTo)) {
    try {
      await db.exec(readFileSync(join(migrationsDir, f), 'utf8'));
    } catch (e) {
      throw new Error(`Migration ${f} failed: ${e.message}`);
    }
  }
  return new Harness(db);
}

class Harness {
  constructor(db) {
    this.db = db;
    this.passed = 0;
  }
  async signup(email, username) {
    const meta = username ? JSON.stringify({ username }) : '{}';
    await this.admin();
    const r = await this.db.query(
      `insert into auth.users (email, raw_user_meta_data) values ($1, $2::jsonb) returning id`,
      [email, meta],
    );
    return r.rows[0].id;
  }
  async admin() {
    await this.db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false);`);
  }
  async as(userId) {
    await this.db.exec(`reset role;`);
    await this.db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [userId ?? '']);
    await this.db.exec(`set role ${userId ? 'authenticated' : 'anon'};`);
    return this;
  }
  async q(sql, params = []) {
    return (await this.db.query(sql, params)).rows;
  }
  async one(sql, params = []) {
    return (await this.q(sql, params))[0];
  }
  async ok(name, fn) {
    try {
      await fn();
      this.passed++;
    } catch (e) {
      throw new Error(`✗ ${name}: ${e.message}`);
    }
  }
  async fails(name, sql, params = []) {
    let threw = false;
    try {
      await this.db.query(sql, params);
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`✗ ${name}: expected an error but the query succeeded`);
    this.passed++;
  }
  eq(name, actual, expected) {
    const a = JSON.stringify(actual);
    const b = JSON.stringify(expected);
    if (a !== b) throw new Error(`✗ ${name}: expected ${b}, got ${a}`);
    this.passed++;
  }
}
