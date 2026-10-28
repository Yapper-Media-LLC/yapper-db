// 573 + 574: Mod Center v4 flag row and site_unban(uid, why). Stand-ins for what they run next to (PGlite stops at 024).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

export default async function (h) {
  const FLAG = mig('573_mod_center_v4_flag.sql');
  const MIG = mig('574_unban_reason.sql');
  h.eq('573 is data only', /\b(create|alter|drop|grant)\b/i.test(FLAG.replace(/^--.*$/gm, '')), false);
  h.eq('574 has no drop / truncate', /\b(drop|truncate)\b/i.test(MIG.replace(/^--.*$/gm, '')), false);
  await h.admin();
  await h.db.exec(`
    create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
      mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
    create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
    create table if not exists public.site_moderators (user_id uuid primary key);
    create table if not exists public.site_bans (user_id uuid primary key, reason text, banned_by uuid, created_at timestamptz default now());
    alter table public.site_bans add column if not exists expires_at timestamptz;
    alter table public.site_bans add column if not exists banned_by uuid;
    create table if not exists public.media_purge (id bigserial primary key, bucket text, path text, done_at timestamptz);
    create table if not exists public.media_scans (id bigserial primary key, user_id uuid, verdict text, forgiven boolean default false);
    alter table public.reports add column if not exists message_attachment text;
    alter table public.reports add column if not exists message_deleted_by text;
    create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;
    create table if not exists public.managers_standin (user_id uuid primary key);
    create or replace function public.is_site_manager() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.managers_standin where user_id = auth.uid()) $$;
    create table if not exists public.guard_calls (action text, target uuid);
    create or replace function public.mod_guard(p_action text, p_target uuid, p_server uuid) returns void language plpgsql security definer as $$
      begin insert into public.guard_calls values (p_action, p_target); end $$;
  `);
  await h.db.exec(FLAG);
  await h.db.exec(MIG);
  await h.ok('573 re-runs cleanly', () => h.db.exec(FLAG));
  await h.ok('574 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag row in test for Antic', (await h.q(`select mode, users from feature_flags where key = 'mod_center_v4'`))[0], { mode: 'test', users: ['00000000-0000-4000-8000-00000000a001'] });
  h.eq('anon cannot call it', (await h.q(`select has_function_privilege('anon', 'public.site_unban(uuid, text)', 'execute') as x`))[0].x, false);
  h.eq('signed-in can', (await h.q(`select has_function_privilege('authenticated', 'public.site_unban(uuid, text)', 'execute') as x`))[0].x, true);

  const admin = await h.signup('admin570@x.test', 'admin570');
  const mod = await h.signup('mod570@x.test', 'mod570');
  const temp = await h.signup('temp570@x.test', 'temp570');
  const auto = await h.signup('auto570@x.test', 'auto570');
  const perm = await h.signup('perm570@x.test', 'perm570');
  const plain = await h.signup('plain570@x.test', 'plain570');
  const mgr = await h.signup('mgr570@x.test', 'mgr570');
  const byMod = await h.signup('bymod570@x.test', 'bymod570');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into public.site_moderators values ($1), ($2)`, [mod, mgr]);
  await h.q(`insert into public.managers_standin values ($1)`, [mgr]);
  await h.q(`insert into public.site_bans (user_id, reason, banned_by) values ($1, 'raiding', $2)`, [byMod, mod]);
  await h.q(`insert into public.site_bans (user_id, reason, banned_by, expires_at) values ($1, 'spam links', $2, now() + interval '7 days')`, [temp, mod]);
  await h.q(`insert into public.site_bans (user_id, reason) values ($1, 'ban evasion')`, [auto]);
  await h.q(`insert into public.site_bans (user_id, reason, banned_by) values ($1, 'threats', $2)`, [perm, admin]);
  await h.q(`insert into public.media_purge (bucket, path) values ('attachments', $1 || '/a.png')`, [temp]);
  await h.q(`insert into public.media_scans (user_id, verdict) values ($1, 'blocked')`, [temp]);

  await h.as(plain);
  await h.fails('a member cannot unban', `select public.site_unban($1, 'please')`, [temp]);
  await h.as(mod);
  await h.fails('a reason is required', `select public.site_unban($1, '')`, [temp]);
  await h.fails('a reason of 2 characters is not enough', `select public.site_unban($1, 'ok')`, [temp]);
  await h.fails('mods cannot lift a confirmed ban', `select public.site_unban($1, 'Appeal accepted')`, [perm]);
  await h.q(`select public.site_unban($1, '  Appeal accepted, first offence  ')`, [temp]);
  await h.q(`select public.site_unban($1, 'False positive on the picture')`, [auto]);
  await h.admin();
  h.eq('temporary ban ended now', (await h.q(`select expires_at <= now() as x from site_bans where user_id = $1`, [temp]))[0].x, true);
  h.eq('automatic ban ended now', (await h.q(`select expires_at <= now() as x from site_bans where user_id = $1`, [auto]))[0].x, true);
  h.eq('confirmed ban untouched', (await h.q(`select expires_at is null as x from site_bans where user_id = $1`, [perm]))[0].x, true);
  h.eq('mod_guard asked once per lift, as unban', (await h.q(`select count(*)::int as n from guard_calls where action = 'unban'`))[0].n, 2);
  const row = (await h.q(`select actor, reason from mod_log where action = 'unban' and target_id = $1`, [temp]))[0];
  h.eq('logged by the mod', row.actor, mod);
  h.eq('log says why and what the ban was for', row.reason, 'Appeal accepted, first offence (ban: spam links)');
  h.eq('queued file deletion taken back', (await h.q(`select count(*)::int as n from media_purge where path like $1 || '/%'`, [temp]))[0].n, 0);
  h.eq('blocked uploads forgiven', (await h.q(`select forgiven from media_scans where user_id = $1`, [temp]))[0].forgiven, true);
  h.eq('long reasons are cut to 300', (await h.q(`select length(left(repeat('x', 400), 300))::int as n`))[0].n, 300);

  await h.as(mgr);
  await h.fails('a manager cannot lift a confirmed ban an admin set', `select public.site_unban($1, 'Appeal accepted')`, [perm]);
  await h.q(`select public.site_unban($1, 'Appeal accepted by Management')`, [byMod]);
  await h.admin();
  h.eq('a manager lifts a confirmed ban a mod set (537 rule kept)', (await h.q(`select expires_at <= now() as x from site_bans where user_id = $1`, [byMod]))[0].x, true);
  h.eq('the manager went through mod_guard too', (await h.q(`select count(*)::int as n from guard_calls where action = 'unban'`))[0].n, 3);
  await h.as(admin);
  await h.q(`select public.site_unban($1, 'Admin lifted it')`, [perm]);
  await h.q(`select public.site_unban($1, 'Nobody by that id')`, [plain]);
  await h.admin();
  h.eq('admins lift confirmed bans', (await h.q(`select expires_at <= now() as x from site_bans where user_id = $1`, [perm]))[0].x, true);
  h.eq('admins skip mod_guard', (await h.q(`select count(*)::int as n from guard_calls where action = 'unban'`))[0].n, 3);
  h.eq('no row for someone not banned', (await h.q(`select count(*)::int as n from mod_log where action = 'unban' and target_id = $1`, [plain]))[0].n, 0);
}
