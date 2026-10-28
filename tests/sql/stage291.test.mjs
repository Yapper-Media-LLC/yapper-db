// 291: voice_report_log for all staff (not users, not anon), only real voice reports, with what staff did;
// resolve_report logs reopening a closed report with who had closed it.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '291_voice_log.sql'), 'utf8');

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
  await h.db.exec(MIG);
  await h.ok('291 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag made in test mode', (await h.one(`select mode from feature_flags where key = 'voice_log'`)).mode, 'test');

  const rep = await h.signup('rep@test.dev', 'rep');
  const tgt = await h.signup('tgt@test.dev', 'tgt');
  const mod = await h.signup('mod@test.dev', 'mod');
  const mod2 = await h.signup('mod2@test.dev', 'mod2');
  await h.admin();
  await h.q(`insert into staff_standin values ($1), ($2)`, [mod, mod2]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [rep])).id;
  const vc = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('vc', 'voice', $1, $2) returning id`, [sid, rep])).id;
  const text = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('chat', 'text', $1, $2) returning id`, [sid, rep])).id;
  const real = (await h.one(`insert into reports (reporter_id, target_id, channel_id, server_id, reason, details, status, resolved_by, resolved_at)
    values ($1, $2, $3, $4, 'harassment', '[voice] yelling', 'dismissed', $5, now()) returning id`, [rep, tgt, vc, sid, mod])).id;
  await h.q(`insert into reports (reporter_id, target_id, channel_id, reason, details) values ($1, $2, $3, 'harassment', '[voice] fake')`, [rep, tgt, text]);
  await h.q(`insert into mod_log (actor, action, target_id, reason) values ($1, 'warn', $2, 'calm down')`, [mod, tgt]);

  await h.as(rep);
  await h.fails('a normal user can’t read the voice log', `select * from voice_report_log()`);
  await h.as(mod2);
  const rows = await h.q(`select * from voice_report_log()`);
  h.eq('staff see only the real voice report', rows.map((r) => r.id), [real]);
  h.eq('with who closed it', rows[0].resolved_by, mod);
  h.eq('and what staff did', rows[0].actions.map((a) => a.action), ['warn']);
  h.eq('channel name shown', rows[0].channel_name, 'vc');

  await h.q(`select resolve_report($1, 'open')`, [real]);
  const log = await h.one(`select actor, action, reason from mod_log where action = 'report_reopened'`);
  await h.admin();
  h.eq('reopen is logged by the mod who reopened it', [log.actor, log.action], [mod2, 'report_reopened']);
  h.eq('with who had closed it', log.reason, 'Was dismissed by mod');
}
