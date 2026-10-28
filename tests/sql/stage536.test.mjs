// 536: CSAM match queue. Stand-ins for what 536 runs next to (PGlite stops at 024).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '536_csam_queue.sql'), 'utf8');

export default async function (h) {
  h.eq('536 has no drop / delete / truncate', /\b(drop|delete\s+from|truncate)\b/i.test(MIG), false);
  await h.admin();
  await h.db.exec(`
    create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
      mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
    create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
    create table if not exists public.site_admins (user_id uuid primary key);
    create table if not exists public.site_bans (user_id uuid primary key, reason text, banned_by uuid, created_at timestamptz default now());
    create table if not exists public.account_freezes (user_id uuid primary key, reason text, by uuid, created_at timestamptz default now());
    create table if not exists public.media_scans (bucket text not null, path text not null, user_id uuid, score real not null default 0,
      verdict text not null default 'ok', scanned_at timestamptz not null default now(), primary key (bucket, path));
    alter table public.signup_log add column if not exists user_id uuid;
    alter table auth.users add column if not exists created_at timestamptz default now();
    alter table auth.users add column if not exists last_sign_in_at timestamptz;
    create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
  `);
  await h.db.exec(MIG);
  await h.db.exec(MIG); // re-runnable

  const boss = await h.signup('boss536@x.test', 'boss536');
  const bad = await h.signup('bad536@x.test', 'bad536');
  const other = await h.signup('other536@x.test', 'other536');
  await h.q(`insert into public.site_admins values ($1)`, [boss]);
  await h.q(`insert into public.media_scans (bucket, path, user_id) values ('attachments', $1, $2)`, [`${bad}/r2-1-abc.png`, bad]);
  await h.q(`insert into public.signup_log (ip, user_id) values ('203.0.113.9', $1)`, [bad]);
  const dm = (await h.one(`insert into public.channels (kind, name) values ('group', 'g536') returning id`)).id;
  await h.q(`insert into public.messages (channel_id, author_id, content, attachment_path) values ($1, $2, 'look', $3)`, [dm, bad, `${bad}/r2-1-abc.png`]);

  h.eq('bucket is private', (await h.one(`select public from storage.buckets where id = 'evidence'`)).public, false);
  h.eq('flag in test', (await h.one(`select mode from public.feature_flags where key = 'csam_queue'`)).mode, 'test');

  // Not admins: refused everywhere, and the table itself is closed.
  await h.as(bad);
  await h.fails('member cannot add', `select public.csam_add('attachments', $1)`, [`${bad}/x.png`]);
  await h.fails('member cannot list', `select * from public.csam_cases_list('all')`);
  await h.fails('member cannot read table', `select * from public.csam_cases`);
  await h.admin();
  await h.q(`set role anon`);
  await h.fails('anon cannot add', `select public.csam_add('attachments', 'a/b.png')`);
  await h.admin();

  await h.as(boss);
  await h.fails('bad bucket', `select public.csam_add('proofs', 'a/b.png')`);
  await h.fails('bad path', `select public.csam_add('attachments', '../etc/passwd')`);
  await h.fails('dot-dot file name', `select public.csam_add('attachments', 'abc/..')`);

  // A file in an attachment message, found through the scan record.
  const c1 = (await h.one(`select public.csam_add('attachments', $1) as id`, [`${bad}/r2-1-abc.png`])).id;
  const again = (await h.one(`select public.csam_add('attachments', $1) as id`, [`${bad}/r2-1-abc.png`])).id;
  h.eq('same file, same case', again, c1);
  // No scan record: the uploader comes from the path.
  const c2 = (await h.one(`select public.csam_add('avatars', $1, 'manual', 'from a report') as id`, [`${other}/av.webp`])).id;
  // A path that names nobody: case without a user.
  const c3 = (await h.one(`select public.csam_add('icons', 'webhooks/hook.png') as id`)).id;
  // The scan record wins over the path's folder.
  await h.admin();
  await h.q(`insert into public.media_scans (bucket, path, user_id) values ('banners', $1, $2)`, [`${other}/b.png`, bad]);
  await h.as(boss);
  const c4 = (await h.one(`select public.csam_add('banners', $1) as id`, [`${other}/b.png`])).id;

  const rows = await h.q(`select * from public.csam_cases_list('open')`);
  h.eq('four open cases', rows.length, 4);
  h.eq('scan beats path', rows.find((r) => r.id === c4).user_id, bad);
  const r1 = rows.find((r) => r.id === c1);
  h.eq('uploader from scan', r1.user_id, bad);
  h.eq('username', r1.username, 'bad536');
  h.eq('email', r1.email, 'bad536@x.test');
  h.eq('signup ip', r1.signup_ip, '203.0.113.9');
  h.eq('not frozen yet', r1.frozen, false);
  h.eq('uploader from path', rows.find((r) => r.id === c2).user_id, other);
  h.eq('message context saved', r1.context.length, 1);
  h.eq('context text', r1.context[0].content, 'look');
  // Snapshot survives: the sign-up log row and the account email change, the case keeps what it saw.
  await h.admin();
  await h.q(`update auth.users set email = 'changed@x.test' where id = $1`, [bad]);
  await h.q(`update public.signup_log set ip = '0.0.0.0' where user_id = $1`, [bad]);
  await h.as(boss);
  const snap = (await h.q(`select * from public.csam_cases_list('open')`)).find((r) => r.id === c1);
  h.eq('email kept', snap.email, 'bad536@x.test');
  h.eq('ip kept', snap.signup_ip, '203.0.113.9');
  h.eq('no uploader', rows.find((r) => r.id === c3).user_id, null);

  await h.fails('reported needs number', `select public.csam_set($1, 'reported')`, [c1]);
  await h.fails('not_csam needs note', `select public.csam_set($1, 'not_csam')`, [c3]);
  await h.fails('unknown status', `select public.csam_set($1, 'gone')`, [c1]);
  await h.q(`select public.csam_set($1, 'confirmed')`, [c1]);
  h.eq('confirmed stays open', (await h.q(`select id from public.csam_cases_list('open') where id = $1`, [c1])).length, 1);
  await h.q(`select public.csam_set($1, 'reported', ' 123456789 ')`, [c1]);
  await h.q(`select public.csam_set($1, 'not_csam', null, 'cartoon, false match')`, [c3]);

  await h.admin();
  const done = await h.one(`select status, ncmec_report_id, reported_at is not null as r, keep_until > now() + interval '364 days' as kept, handled_by from public.csam_cases where id = $1`, [c1]);
  h.eq('reported', done.status, 'reported');
  h.eq('number trimmed', done.ncmec_report_id, '123456789');
  h.eq('reported_at set', done.r, true);
  h.eq('kept a year', done.kept, true);
  h.eq('handled by', done.handled_by, boss);
  h.eq('done list', (await h.q(`select count(*)::int as n from public.csam_cases where status in ('reported', 'not_csam')`))[0].n, 2);
  h.eq('logged', (await h.q(`select 1 from public.mod_log where action in ('csam_case', 'csam_reported', 'csam_not_csam', 'csam_confirmed')`)).length >= 5, true);
}
