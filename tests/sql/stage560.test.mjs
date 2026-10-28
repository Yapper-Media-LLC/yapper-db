// 560: Mod Center v3: resolve_reports (several at once, resolve_report's rules) and admin_delete_messages.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(`
    alter table public.reports add column if not exists server_id uuid;
    alter table public.reports add column if not exists voice_clip_path text;
    create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
      mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
    create table if not exists public.staff_standin (user_id uuid primary key);
    create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
      target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
  `);
  await h.db.exec(mig('291_voice_log.sql'));
  await h.db.exec(mig('560_mod_center_v3.sql'));
  await h.ok('560 re-runs cleanly', () => h.db.exec(mig('560_mod_center_v3.sql')));
  h.eq('flag row in test for Antic', (await h.q(`select mode, users from feature_flags where key = 'mod_center_v3'`))[0], { mode: 'test', users: ['00000000-0000-4000-8000-00000000a001'] });
  const admin = await h.signup('admin@test.dev', 'admin');
  const mod = await h.signup('mod@test.dev', 'mod');
  const user = await h.signup('u@test.dev', 'user');
  const bad = await h.signup('b@test.dev', 'bad');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into staff_standin values ($1), ($2)`, [mod, admin]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  await h.q(`update profiles set created_at = now() - interval '30 days' where id in ($1, $2)`, [bad, user]);
  const rep = async () => (await h.q(`insert into reports (reporter_id, target_id, reason, details) values ($1, $2, 'spam', '') returning id`, [user, bad]))[0].id;
  const r1 = await rep(); const r2 = await rep(); const r3 = await rep();
  h.eq('a member can not resolve', String(await call(user, `select resolve_reports(array[$1]::uuid[], 'dismissed')`, [r1])).includes('Not allowed'), true);
  h.eq('a mod closes two at once', Number(await call(mod, `select resolve_reports(array[$1, $2]::uuid[], 'actioned')`, [r1, r2])), 2);
  h.eq('both actioned by the mod', (await h.q(`select count(*)::int n from reports where id in ($1, $2) and status = 'actioned' and resolved_by = $3`, [r1, r2, mod]))[0].n, 2);
  h.eq('the third is still open', (await h.q(`select status from reports where id = $1`, [r3]))[0].status, 'open');
  h.eq('empty list: 0', Number(await call(mod, `select resolve_reports('{}'::uuid[], 'dismissed')`)), 0);
  h.eq('bad status refused', String(await call(mod, `select resolve_reports(array[$1]::uuid[], 'weird')`, [r3])).includes('Bad status'), true);
  const sid = (await h.q(`insert into servers (name, owner_id) values ('s', $1) returning id`, [admin]))[0].id;
  const cid = (await h.q(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, admin]))[0].id;
  const m1 = (await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'one') returning id`, [cid, bad]))[0].id;
  const m2 = (await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'two') returning id`, [cid, bad]))[0].id;
  h.eq('mods can not use the admin batch delete', String(await call(mod, `select admin_delete_messages(array[$1]::uuid[])`, [m1])).includes('Admins only'), true);
  h.eq('admin deletes two', Number(await call(admin, `select admin_delete_messages(array[$1, $2]::uuid[])`, [m1, m2])), 2);
  h.eq('gone', (await h.q(`select count(*)::int n from messages where id in ($1, $2)`, [m1, m2]))[0].n, 0);
}
