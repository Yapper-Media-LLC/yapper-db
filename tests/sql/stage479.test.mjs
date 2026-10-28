// 479: approving a verification refuses a channel already on another account, and a name that no longer matches.
// NOT applied (database freeze Oct 25). Starts from stage 24 with stand-ins for the live pieces review_verification uses.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '479_verify_one_account_per_channel.sql'), 'utf8');
export const base = 24;

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists verified_as text;
create table if not exists public.verification_requests (
  id uuid primary key default gen_random_uuid(), user_id uuid not null, platform text, handle text, link text, note text,
  proof_path text, status text not null default 'pending', reviewed_by uuid, reviewed_at timestamptz, review_note text not null default '',
  created_at timestamptz default now());
create table if not exists public.site_admins (user_id uuid primary key);
create table if not exists public.site_moderators (user_id uuid primary key);
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$ select public.is_site_admin() or exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language sql as $$ select $$;
create or replace function public.bc(topic text, ev text, op text, tbl text, sch text, n text, o text) returns void language sql as $$ select $$;
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text);
create or replace function public.skeleton(t text) returns text language sql immutable as $$ select lower(coalesce(t, '')) $$;
-- name_key is live but not in a migration file; same body as live (read Oct 25).
create or replace function public.name_key(t text) returns text language sql immutable as $$ select regexp_replace(translate(lower(coalesce(t, '')), '01i345780@$', 'olleastbooas'), '[^a-z0-9]', '', 'g') $$;
create or replace function public.verify_name_key(t text) returns text language sql immutable set search_path = public as $$
  select regexp_replace(public.skeleton(regexp_replace(normalize(regexp_replace(coalesce(t, ''), '^\\s*@+', ''), NFKD), '[\\u0300-\\u036f]', '', 'g')), '[^a-z0-9]', '', 'g') $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('479 runs', () => h.db.exec(MIG));
  await h.ok('479 re-runs cleanly', () => h.db.exec(MIG));

  const admin = await h.signup('admin@test.dev', 'boss');
  const mod = await h.signup('mod@test.dev', 'modder');
  const a = await h.signup('a@test.dev', 'BigChannel');
  const b = await h.signup('b@test.dev', 'big_channel');
  const c = await h.signup('c@test.dev', 'other');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  // Two accounts applied for the same channel while neither was verified yet.
  const ra = (await h.one(`insert into verification_requests (user_id, platform, handle, link) values ($1, 'youtube', 'BigChannel', 'https://youtube.com/@BigChannel') returning id`, [a])).id;
  const rb = (await h.one(`insert into verification_requests (user_id, platform, handle, link) values ($1, 'youtube', 'BigChannel', 'https://youtube.com/@BigChannel') returning id`, [b])).id;
  const rc = (await h.one(`insert into verification_requests (user_id, platform, handle, link) values ($1, 'twitch', 'Streamer', 'https://twitch.tv/streamer') returning id`, [c])).id;

  await h.as(admin);
  await h.ok('first approval works', () => h.q(`select review_verification($1, true)`, [ra]));
  await h.admin();
  h.eq('first account verified', (await h.one(`select verified_as v from profiles where id = $1`, [a])).v, 'YouTube · BigChannel');

  await h.as(admin);
  h.eq('second account for the same channel is refused',
    await h.q(`select review_verification($1, true)`, [rb]).then(() => 'approved', (e) => e.message),
    'That channel is already verified on another account (@BigChannel). Reject this one, or take the badge off the other account first.');
  await h.admin();
  h.eq('second account not verified', (await h.one(`select verified_as v from profiles where id = $1`, [b])).v, null);
  h.eq('second request still open', (await h.one(`select status from verification_requests where id = $1`, [rb])).status, 'pending');
  await h.as(admin);
  await h.ok('rejecting the duplicate still works', () => h.q(`select review_verification($1, false, 'dupe')`, [rb]));

  // Renamed away from the channel while waiting.
  await h.as(admin);
  await h.fails('name no longer matches: refused', `select review_verification($1, true)`, [rc]);
  await h.admin();
  await h.q(`update profiles set display_name = 'Streamer' where id = $1`, [c]);
  await h.as(admin);
  await h.ok('matching display name: approved', () => h.q(`select review_verification($1, true)`, [rc]));

  // Mods still can't approve; anon can't call it.
  await h.admin();
  const rd = (await h.one(`insert into verification_requests (user_id, platform, handle, link) values ($1, 'x', 'modder', 'https://x.com/modder') returning id`, [admin])).id;
  await h.as(mod);
  await h.fails('mods cannot approve', `select review_verification($1, true)`, [rd]);
  await h.as(null);
  await h.fails('anon cannot call it', `select review_verification($1, true)`, [rd]);
}
