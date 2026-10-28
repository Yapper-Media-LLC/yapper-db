// 213: voice report clips. Private bucket (upload only into your own folder, staff-only reads), attach_report_clip
// (only your own fresh voice report, fixed path, once), and the cleanup lists. Runs on stage 24 plus stand-ins
// for the later bits it touches (feature flags, staff, server_id on reports, objects.created_at).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
alter table storage.objects add column if not exists created_at timestamptz not null default now();
alter table public.reports add column if not exists server_id uuid;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[]);
create table if not exists public.staff_standin (user_id uuid primary key);
grant select on public.staff_standin to authenticated;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable
  as $$ select exists (select 1 from public.feature_flags where key = k and mode <> 'off') $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', '213_voice_report_clips.sql'), 'utf8'));

  const a = await h.signup('a@x.com', 'reporter');
  const b = await h.signup('b@x.com', 'target');
  const staff = await h.signup('s@x.com', 'staffer');
  await h.admin();
  await h.q(`insert into public.staff_standin values ($1)`, [staff]);

  const flag = await h.one(`select mode from public.feature_flags where key = 'voice_report_clips'`);
  h.eq('flag starts in test mode', flag?.mode, 'test');
  const bucket = await h.one(`select public, allowed_mime_types from storage.buckets where id = 'report_clips'`);
  h.eq('bucket is private', bucket?.public, false);

  const mk = async (details, ago = '0 minutes') =>
    (await h.one(`insert into public.reports (reporter_id, target_id, reason, details, created_at)
                  values ($1, $2, 'harassment', $3, now() - $4::interval) returning id`, [a, b, details, ago])).id;
  const rid = await mk('[voice] yelling slurs');
  const textRid = await mk('spam in general');
  const oldRid = await mk('[voice] earlier', '20 minutes');

  // Uploads: own folder only.
  await h.as(a);
  await h.ok('reporter uploads into own folder', () => h.q(`insert into storage.objects (bucket_id, name) values ('report_clips', $1)`, [`${a}/${rid}.wav`]));
  await h.fails('cannot upload into someone else\'s folder', `insert into storage.objects (bucket_id, name) values ('report_clips', $1)`, [`${b}/${rid}.wav`]);
  await h.fails('cannot upload for a text report', `insert into storage.objects (bucket_id, name) values ('report_clips', $1)`, [`${a}/${textRid}.wav`]);
  await h.fails('cannot upload for an old report', `insert into storage.objects (bucket_id, name) values ('report_clips', $1)`, [`${a}/${oldRid}.wav`]);
  await h.fails('cannot upload random files', `insert into storage.objects (bucket_id, name) values ('report_clips', $1)`, [`${a}/movie.mp4`]);
  await h.fails('cannot upload for a made-up report', `insert into storage.objects (bucket_id, name) values ('report_clips', $1)`, [`${a}/00000000-0000-4000-8000-000000000000.wav`]);

  // Reads: staff only, not even the reporter.
  h.eq('reporter cannot read clips', (await h.q(`select name from storage.objects where bucket_id = 'report_clips'`)).length, 0);
  await h.as(b);
  h.eq('target cannot read clips', (await h.q(`select name from storage.objects where bucket_id = 'report_clips'`)).length, 0);
  await h.as(staff);
  h.eq('staff can read clips', (await h.q(`select name from storage.objects where bucket_id = 'report_clips'`)).length, 1);

  // Attaching.
  await h.as(b);
  await h.fails('someone else cannot attach to my report', `select public.attach_report_clip($1)`, [rid]);
  await h.as(a);
  await h.fails('no clip on a text report', `select public.attach_report_clip($1)`, [textRid]);
  await h.fails('too late for an old report', `select public.attach_report_clip($1)`, [oldRid]);
  await h.ok('reporter attaches clip', () => h.q(`select public.attach_report_clip($1)`, [rid]));
  await h.fails('only one clip per report', `select public.attach_report_clip($1)`, [rid]);
  const rid2 = await (async () => { await h.admin(); return mk('[voice] again'); })();
  await h.as(a);
  await h.fails('attach fails without an upload', `select public.attach_report_clip($1)`, [rid2]);
  await h.admin();
  h.eq('path stored on the report', (await h.one(`select voice_clip_path from public.reports where id = $1`, [rid])).voice_clip_path, `${a}/${rid}.wav`);

  // Flag off: no attaching.
  await h.q(`update public.feature_flags set mode = 'off' where key = 'voice_report_clips'`);
  await h.q(`insert into storage.objects (bucket_id, name) values ('report_clips', $1)`, [`${a}/${rid2}.wav`]);
  await h.as(a);
  await h.fails('flag off blocks attaching', `select public.attach_report_clip($1)`, [rid2]);
  await h.admin();
  await h.q(`update public.feature_flags set mode = 'test' where key = 'voice_report_clips'`);

  // Cleanup lists (service role only).
  await h.as(a);
  await h.fails('users cannot list due clips', `select * from public.report_clips_due(10)`);
  await h.fails('users cannot clear clips', `select public.report_clips_cleared(array['x'])`);
  await h.admin();
  h.eq('nothing due yet', (await h.q(`select * from public.report_clips_due(10)`)).length, 0);
  await h.q(`update public.reports set status = 'actioned', resolved_at = now() - interval '31 days' where id = $1`, [rid]);
  await h.q(`update storage.objects set created_at = now() - interval '2 days' where name = $1`, [`${a}/${rid2}.wav`]);
  const due = (await h.q(`select path from public.report_clips_due(10) order by 1`)).map((r) => r.path).sort();
  h.eq('resolved 30+ days and unlinked uploads are due', due, [`${a}/${rid}.wav`, `${a}/${rid2}.wav`].sort());
  await h.q(`select public.report_clips_cleared(array[$1])`, [`${a}/${rid}.wav`]);
  h.eq('cleared path is removed from the report', (await h.one(`select voice_clip_path from public.reports where id = $1`, [rid])).voice_clip_path, null);

  // Re-runnable.
  await h.ok('migration runs twice', () => h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', '213_voice_report_clips.sql'), 'utf8')));
}
