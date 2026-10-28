// 528: a ban no longer purges the report clips the banned person attached to reports about others, and cocainee.pro
// is in lib/linkhosts.json (it's in link_hosts live since 526). Base 24, then 025 (media_purge + the ban trigger; the
// storage stand-in needs created_at first), stand-in for is_frozen (281).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('528_ban_keeps_report_clips.sql');
const LIST = JSON.parse(readFileSync(join(here, '..', '..', 'lib', 'linkhosts.json'), 'utf8'));

const STANDINS = `
alter table storage.objects add column if not exists created_at timestamptz not null default now();
create table if not exists public.account_freezes (user_id uuid primary key);
create or replace function public.is_frozen(uid uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.account_freezes where user_id = uid) $$;
insert into storage.buckets (id, name) values ('report_clips', 'report_clips'), ('attachments', 'attachments'), ('avatars', 'avatars')
  on conflict do nothing;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('025_media_scans.sql'));
  // Queued by a ban before 528: the clip waits for an admin's Purge press. A finished one and other buckets stay.
  await h.db.exec(`insert into media_purge (bucket, path) values ('report_clips', 'x/waiting.wav'), ('attachments', 'x/waiting.png');
    insert into media_purge (bucket, path, done_at) values ('report_clips', 'x/done.wav', now());`);
  await h.db.exec(MIG);
  h.eq('528 takes queued report clips off the purge list, nothing else',
    (await h.q(`select bucket || ':' || path p from media_purge order by 1`)).map((r) => r.p), ['attachments:x/waiting.png', 'report_clips:x/done.wav']);
  await h.db.exec(`truncate media_purge`);
  await h.ok('528 re-runs cleanly', () => h.db.exec(MIG));

  h.eq('cocainee.pro is in lib/linkhosts.json loggers', LIST.loggers.includes('cocainee.pro'), true);

  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  await h.db.query(
    `insert into storage.objects (bucket_id, name) values
       ('report_clips', $1 || '/r1.wav'), ('attachments', $1 || '/pic.png'), ('avatars', $1 || '/a.webp'),
       ('attachments', $2 || '/kept.png'), ('report_clips', $2 || '/r2.wav')`, [bob, cat]);

  await h.db.query(`insert into site_bans (user_id, reason) values ($1, 'test')`, [bob]);
  const queued = (await h.q(`select bucket, path from media_purge order by bucket, path`)).map((r) => `${r.bucket}:${r.path}`);
  h.eq('a ban queues the person\'s own uploads but not their report clips', queued, [`attachments:${bob}/pic.png`, `avatars:${bob}/a.webp`]);

  await h.db.query(`insert into account_freezes (user_id) values ($1)`, [cat]);
  await h.db.query(`insert into site_bans (user_id, reason) values ($1, 'test')`, [cat]);
  h.eq('a frozen account still keeps everything', (await h.one(`select count(*)::int n from media_purge where path like $1 || '/%'`, [cat])).n, 0);
}
