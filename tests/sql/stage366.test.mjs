// 366 mods review bots: can_review_bots, bot_review_queue and admin_verify_bot open to site mods with mod_bot_review on.
// PGlite stops at 24, so this adds stand-ins for what the migration touches (live versions are bigger).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '366_mod_bot_review.sql'), 'utf8');
const BOT = '36600000-0000-4000-8000-000000000001';
const OWN = '36600000-0000-4000-8000-000000000002';

const STANDINS = `
alter table public.profiles add column if not exists plus_until timestamptz;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) $$;
create table if not exists public.bots (id uuid primary key, owner_id uuid references public.profiles (id), name text, description text,
  public boolean not null default false, unlisted boolean not null default false, verified_at timestamptz, review_note text,
  submitted_at timestamptz, posts bigint not null default 0);
create table if not exists public.bot_servers (bot_id uuid, server_id uuid);
create table if not exists public.bot_commands (bot_id uuid, name text);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.feature_flags f where f.key = k and (f.mode = 'everyone' or (f.mode = 'test' and (auth.uid() = any(f.users) or sid = any(f.servers))))) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const antic = await h.signup('antic366@test.dev', 'antic366');
  const mod = await h.signup('mod366@test.dev', 'mod366');
  const mod2 = await h.signup('mod2366@test.dev', 'mod2366');
  const maker = await h.signup('maker366@test.dev', 'maker366');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2)`, [mod, mod2]);
  await h.q(`insert into bots (id, owner_id, name, public, submitted_at) values ($1, $2, 'Helper', true, now()), ($3, $4, 'ModBot', true, now())`, [BOT, maker, OWN, mod]);

  await h.db.exec(MIG);
  await h.ok('366 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'mod_bot_review'`)).mode, 'test');

  // ---- flag off for this mod: nothing ----
  await h.as(mod);
  h.eq('mod without the flag sees no queue', (await h.one(`select count(*)::int n from bot_review_queue()`)).n, 0);
  await h.fails('mod without the flag cannot verify', `select admin_verify_bot($1, true)`, [BOT]);
  await h.as(maker);
  h.eq('regular user sees no queue', (await h.one(`select count(*)::int n from bot_review_queue()`)).n, 0);
  await h.fails('regular user cannot verify', `select admin_verify_bot($1, true)`, [BOT]);

  // ---- admins as before ----
  await h.as(antic);
  h.eq('admin sees the queue', (await h.one(`select count(*)::int n from bot_review_queue()`)).n, 2);

  // ---- flag on for the mods (and the maker, who is not a mod) ----
  await h.admin();
  await h.q(`update feature_flags set users = array[$1, $2, $3]::uuid[] where key = 'mod_bot_review'`, [mod, mod2, maker]);
  await h.as(maker);
  h.eq('flag alone is not enough for a non-mod', (await h.one(`select count(*)::int n from bot_review_queue()`)).n, 0);
  await h.fails('non-mod with the flag cannot verify', `select admin_verify_bot($1, true)`, [BOT]);
  await h.as(mod);
  h.eq('mod with the flag sees the queue', (await h.one(`select count(*)::int n from bot_review_queue()`)).n, 2);
  await h.fails('mod cannot approve their own bot', `select admin_verify_bot($1, true)`, [OWN]);
  await h.fails('mod cannot send back their own bot', `select admin_verify_bot($1, false, 'meh')`, [OWN]);
  await h.q(`select admin_verify_bot($1, true)`, [BOT]);
  await h.admin();
  h.eq('bot verified', (await h.one(`select verified_at is not null v from bots where id = $1`, [BOT])).v, true);
  h.eq('logged under the mod', (await h.one(`select actor, action from mod_log where target_id = $1`, [BOT])), { actor: mod, action: 'bot_verified' });
  await h.as(mod2);
  await h.q(`select admin_verify_bot($1, false, 'No commands yet')`, [OWN]);
  await h.admin();
  h.eq('another mod can send it back', (await h.one(`select public, review_note from bots where id = $1`, [OWN])), { public: false, review_note: 'No commands yet' });

  // ---- suspended mod loses it ----
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [mod]);
  await h.as(mod);
  await h.fails('suspended mod cannot verify', `select admin_verify_bot($1, true)`, [BOT]);
}
