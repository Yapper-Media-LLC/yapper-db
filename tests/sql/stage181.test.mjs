// 181: upload appeals. The stand-ins can't run every migration up to 181, so: 001..024, small stand-ins for the
// later bits 181 uses (expires_at on bans, mod_log, staff checks, the blocklist lookup, report columns), then 181
// twice (it must be re-runnable). Mostly about the ban lift: approving lifts ONLY the image check's own
// automatic ban, never an automod / report auto-ban or a moderator's ban.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const base = 24;

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.media_scans (
  bucket text not null, path text not null, user_id uuid, score real not null,
  verdict text not null check (verdict in ('ok', 'blocked')), scanned_at timestamptz not null default now(),
  forgiven boolean not null default false, phash bigint, details jsonb, primary key (bucket, path)
);
create table if not exists public.media_purge (
  bucket text not null, path text not null, queued_at timestamptz not null default now(), done_at timestamptz,
  primary key (bucket, path)
);
alter table public.reports add column if not exists message_deleted_by text;
create table if not exists public.mod_log (
  id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid,
  message_id uuid, reason text not null default '', created_at timestamptz not null default now()
);
create table if not exists public.site_mods (user_id uuid primary key);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or exists (select 1 from public.site_mods where user_id = auth.uid());
$$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language sql as $$ select $$;
create or replace function public.nsfw_hash_hit(h text) returns boolean language sql stable as $$ select false $$;
`;

const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '181_upload_appeals.sql'), 'utf8');
const IMG = 'Uploading sexual images or videos';

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.ok('181 applies', () => h.db.exec(MIG));
  await h.ok('181 applies again (re-runnable)', () => h.db.exec(MIG));

  const adm = await h.signup('adm@test.dev', 'adm');
  const mod = await h.signup('mod@test.dev', 'mod');
  const img = await h.signup('img@test.dev', 'img'); // banned by the image check
  const spam = await h.signup('spam@test.dev', 'spam'); // banned by automod (also banned_by null)
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [adm]);
  await h.q(`insert into site_mods values ($1)`, [mod]);
  h.eq('quarantine bucket is private', (await h.one(`select public from storage.buckets where id = 'quarantine'`)).public, false);

  // One blocked strike-level upload each, inside the window of their automatic ban.
  for (const [u, reason] of [[img, IMG], [spam, 'Automod: sexual spam']]) {
    await h.q(`insert into media_scans (bucket, path, user_id, score, verdict, scanned_at, details)
               values ('attachments', $1::text || '/a.png', $1::uuid, 0.91, 'blocked', now() - interval '1 minute', jsonb_build_object('sha256', $1::text))`, [u]);
    await h.q(`insert into site_bans (user_id, reason, expires_at, created_at) values ($1::uuid, $2, now() + interval '7 days', now())`, [u, reason]);
    await h.q(`insert into media_purge (bucket, path) values ('attachments', $1::text || '/other.png')`, [u]);
  }

  const appeal = async (u) => {
    await h.as(u);
    return (await h.one(`select appeal_upload('attachments', $1::text || '/a.png', 'it is a cat') id`, [u])).id;
  };
  const aImg = await appeal(img);
  const aSpam = await appeal(spam);

  await h.as(mod);
  const q = await h.one(`select staff_upload_appeals('pending') j`);
  const byUser = Object.fromEntries(q.j.map((r) => [r.user_id, r]));
  h.eq('queue flags the image check ban', byUser[img].auto_banned, true);
  h.eq('queue does not flag an automod ban', byUser[spam].auto_banned, false);
  h.eq('queue never returns storage keys', JSON.stringify(q.j).includes('quarantine_key'), false);

  // A mod approves: strike forgiven, image ban lifted, nothing allowlisted (admins only).
  const rImg = (await h.one(`select staff_decide_appeal($1, true) r`, [aImg])).r;
  h.eq('mod approval lifts the image ban, adds nothing to the allowlist', [rImg.unbanned, rImg.allowed], [true, false]);
  h.eq('no storage key in the result', 'key' in rImg, false);

  await h.as(adm);
  const rSpam = (await h.one(`select staff_decide_appeal($1, true) r`, [aSpam])).r;
  h.eq('admin approval allowlists but does not lift an automod ban', [rSpam.unbanned, rSpam.allowed], [false, true]);

  await h.admin();
  const bans = await h.q(`select user_id, expires_at > now() running from site_bans order by reason`);
  h.eq('only the image ban ended', bans.map((b) => [b.user_id === img ? 'img' : 'spam', b.running]), [['spam', true], ['img', false]]);
  const purge = await h.q(`select split_part(path, '/', 1) = $1 img from media_purge order by 1`, [img]);
  h.eq('lifted ban takes their queued files back out; the other stays queued', purge.map((p) => p.img), [false]);
  h.eq('allowlist holds exact bytes for the admin approval only',
    (await h.q(`select sha256, bucket from nsfw_allowed_hashes`)).map((r) => [r.sha256 === spam, r.bucket]), [[true, 'attachments']]);

  // Allowlist: same bytes pass in messages, not as a (stricter) profile picture, and not at a higher score.
  await h.admin();
  await h.db.exec(`set role service_role`);
  h.eq('allow hit: same bucket and score', (await h.one(`select nsfw_allow_hit($1, 'attachments', 0.91) ok`, [spam])).ok, true);
  h.eq('allow miss: stricter bucket', (await h.one(`select nsfw_allow_hit($1, 'avatars', 0.91) ok`, [spam])).ok, false);
  h.eq('allow miss: higher score', (await h.one(`select nsfw_allow_hit($1, 'attachments', 0.99) ok`, [spam])).ok, false);
  await h.admin();

  await h.as(mod);
  await h.fails('mods cannot take things off the allowlist', `select admin_unallow_appeal($1)`, [aSpam]);
  await h.as(img);
  await h.fails('users cannot read the queue', `select staff_upload_appeals('pending')`);
  await h.fails('users cannot call nsfw_allow_hit', `select nsfw_allow_hit('x', 'attachments', 0.5)`);
  await h.as(adm);
  h.eq('admin takes it off the allowlist', (await h.one(`select admin_unallow_appeal($1) n`, [aSpam])).n, 1);
  // A sure hit (score 1) in the ban window is flagrant: approving another upload's appeal keeps that ban.
  const sure = await h.signup('sure@test.dev', 'sure');
  const hh = await h.signup('hh@test.dev', 'hh');
  await h.admin();
  await h.q(`insert into media_scans (bucket, path, user_id, score, verdict, scanned_at, details) values
             ('attachments', $1::text || '/a.png', $1::uuid, 0.91, 'blocked', now() - interval '2 minutes', '{}'),
             ('attachments', $1::text || '/b.png', $1::uuid, 1, 'blocked', now() - interval '1 minute', '{}')`, [sure]);
  await h.q(`insert into site_bans (user_id, reason, expires_at, created_at) values ($1, $2, now() + interval '7 days', now())`, [sure, IMG]);
  await h.q(`insert into media_scans (bucket, path, user_id, score, verdict, details)
             values ('attachments', $1::text || '/a.png', $1::uuid, 0.5, 'blocked', '{"hashHit": true}')`, [hh]);
  const aSure = await appeal(sure);
  await appeal(hh);
  // The queue reads the stored hashHit; it no longer asks the blocklist per row (stand-in now says "hit" for all).
  await h.admin();
  await h.db.exec(`create or replace function public.nsfw_hash_hit(h text) returns boolean language sql stable as $$ select true $$`);
  await h.q(`update media_scans set phash = 42 where user_id = $1`, [sure]);
  await h.q(`update upload_appeals set phash = 42 where user_id = $1`, [sure]);
  await h.as(mod);
  const q2 = Object.fromEntries((await h.one(`select staff_upload_appeals('pending') j`)).j.map((r) => [r.user_id, r]));
  h.eq('queue known comes from the stored hashHit', [q2[hh].known, q2[sure].known], [true, false]);
  const rSure = (await h.one(`select staff_decide_appeal($1, true) r`, [aSure])).r;
  h.eq('a score of 1 in the window keeps the image ban', rSure.unbanned, false);
  await h.admin();
  h.eq('their ban still runs', (await h.one(`select expires_at > now() running from site_bans where user_id = $1`, [sure])).running, true);
}
