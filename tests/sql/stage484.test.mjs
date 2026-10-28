// 484: gore check. A person's picture in an HQ message needs a scan that went through the gore check
// (media_scans.details ? 'gore') while the flag is on for them; other servers, staff, bots/webhooks (no auth.uid()),
// KLIPY GIFs and the flag off are left alone. The older rules (unchecked file, HQ's 0.6 line) still hold.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.media_scans (bucket text not null, path text not null, user_id uuid, score real not null,
  verdict text not null, details jsonb, primary key (bucket, path));
create or replace function public.media_ok(b text, p text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.media_scans where bucket = b and path = p and verdict = 'ok') $$;
create table if not exists public.image_reviews (sha256 text primary key, user_id uuid, rating text not null, minor boolean not null,
  confidence real not null, reason text not null, model text not null, at timestamptz not null default now());
create table if not exists public.staff_here (user_id uuid primary key);
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_here where user_id = auth.uid()) $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and auth.uid() = any(users)) from public.feature_flags where key = k), false);
$$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('484_gore_check.sql');
  await h.db.exec(MIG);
  await h.ok('484 re-runs cleanly', () => h.db.exec(MIG));
  // The live trigger on messages (025).
  await h.db.exec(`create trigger messages_scanned_media before insert or update of attachment_path on public.messages
    for each row execute function public.require_scanned_media('attachment_path', 'attachments')`);
  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'gore_check'`)).mode, 'test');

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.admin();
  const hq = (await h.one(`insert into servers (name, owner_id) values ('HQ', $1) returning id`, [mod])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [mod])).id;
  await h.q(`update app_settings set default_server_id = $1, new_account_wait = '0 seconds'`, [hq]);
  const hqc = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'general', $1, $2) returning id`, [hq, mod])).id;
  const otc = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'general', $1, $2) returning id`, [other, mod])).id;
  await h.q(`insert into staff_here values ($1)`, [mod]);
  // Old accounts, so the new-account wait and slow mode (024) stay out of the way.
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  await h.q(`update feature_flags set users = array[$1]::uuid[], servers = '{}' where key = 'gore_check'`, [amy]);

  const scan = (path, score, details) => h.q(`insert into media_scans (bucket, path, user_id, score, verdict, details) values ('attachments', $1, null, $2, 'ok', $3)`,
    [path, score, details ? JSON.stringify(details) : null]);
  for (const who of [amy, bob, mod]) {
    await scan(`${who}/plain.png`, 0, { v: 2 });
    await scan(`${who}/checked.png`, 0, { v: 2, gore: { why: 'hq', violence: 'none', confidence: 0.95 } });
    await scan(`${who}/failed.jpg`, 0, { v: 2, gore: { why: 'hq', failed: 'timeout' } });
    await scan(`${who}/clip.mp4`, 0, null);
    await scan(`${who}/old-clip.MP4`, 0, { v: 2, gore: { why: 'hq', skipped: 'video' } });
    await scan(`${who}/klipy.gif`, 0, { source: 'klipy' });
    await scan(`${who}/LOUD.PNG`, 0, { v: 2 });
    await scan(`${who}/edgy.png`, 0.65, { v: 2, gore: { why: 'hq', violence: 'none' } });
  }
  // As the person (auth.uid() set) but past RLS: the trigger is what's tested.
  const send = async (who, channel, path) => {
    await h.admin();
    await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [who ?? '']);
    await h.q(`insert into messages (channel_id, author_id, content, attachment_path) values ($1, $2, 'x', $3)`, [channel, who ?? mod, path]);
  };
  // Refused, and for the reason expected (raid limits from 024 must not be what stopped it).
  const refused = async (name, who, channel, path, why) => {
    let msg = '';
    try { await send(who, channel, path); } catch (e) { msg = e.message; }
    await h.admin();
    h.eq(name, why.test(msg) ? 'refused' : msg || 'went through', 'refused');
  };
  const GORE = /checked for Yapin' HQ/;

  await refused('HQ: a picture that skipped the gore check is refused', amy, hqc, `${amy}/plain.png`, GORE);
  await h.ok('HQ: a checked one goes through', () => send(amy, hqc, `${amy}/checked.png`));
  await h.ok('HQ: a check that timed out was recorded, so it goes through', () => send(amy, hqc, `${amy}/failed.jpg`));
  await refused('HQ: a video that skipped the gore check is refused too', amy, hqc, `${amy}/clip.mp4`, GORE);
  await h.ok('HQ: a video marked skipped (older account) goes through', () => send(amy, hqc, `${amy}/old-clip.MP4`));
  await h.ok('HQ: a KLIPY GIF (our own search, stored by the server) goes through', () => send(amy, hqc, `${amy}/klipy.gif`));
  await refused('HQ: upper-case extensions are covered', amy, hqc, `${amy}/LOUD.PNG`, GORE);
  await refused('HQ: the 0.6 line still holds', amy, hqc, `${amy}/edgy.png`, /too close to the line/);
  await h.ok('another server: no gore check needed', () => send(amy, otc, `${amy}/plain.png`));
  await h.ok('flag off for bob: unchanged', () => send(bob, hqc, `${bob}/plain.png`));
  await h.ok('staff in HQ are left out', () => send(mod, hqc, `${mod}/plain.png`));
  await h.ok('no auth.uid() (bots, webhooks): left out', () => send(null, hqc, `${mod}/plain.png`));
  await refused('an unchecked file is still refused', amy, otc, `${amy}/never-scanned.png`, /hasn't been checked/);

  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'gore_check'`);
  await refused('on for everyone: bob too', bob, hqc, `${bob}/plain.png`, GORE);
  await h.ok('...his checked one goes through', () => send(bob, hqc, `${bob}/checked.png`));

  await h.admin();
  await h.ok('image_reviews takes a violence answer', () => h.q(`insert into image_reviews (sha256, rating, minor, confidence, reason, model, violence, violence_confidence)
    values ('a', 'safe', false, 0.9, 'x', 'm', 'graphic', 0.9)`));
  await h.fails('...only a known one', `insert into image_reviews (sha256, rating, minor, confidence, reason, model, violence) values ('b', 'safe', false, 0.9, 'x', 'm', 'gory')`);
  await h.ok('...or none (older rows)', () => h.q(`insert into image_reviews (sha256, rating, minor, confidence, reason, model) values ('c', 'safe', false, 0.9, 'x', 'm')`));
  h.eq('older rows count as sexual second opinions', (await h.one(`select gore_only from image_reviews where sha256 = 'c'`)).gore_only, false);
}
