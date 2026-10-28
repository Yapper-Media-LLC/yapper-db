// 417 (applied live as 410_creator_program before main took 410): Creator Program: applications, content rewards and review. Starts from stage 24 with stand-ins for what the
// functions use (staff checks, bans, feature_on_for_me, mod_log, the badge and Plus columns, the profile cache ping).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '417_creator_program.sql'), 'utf8');

const STANDINS = `
create table if not exists public.t417_admins (id uuid primary key);
create table if not exists public.t417_banned (id uuid primary key);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
alter table public.mod_log add column if not exists target_id uuid;
alter table public.mod_log add column if not exists reason text;
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
alter table public.profiles add column if not exists verified_as text;
alter table public.profiles add column if not exists plus_until timestamptz;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select exists (select 1 from public.t417_admins where id = auth.uid()) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.t417_banned where id = uid) $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and auth.uid() = any(users)) from public.feature_flags where key = k), false) $$;
create or replace function public.rt_profile_changed(uids uuid[]) returns void language sql as $$ select $$;
`;

const daysLeft = (until) => Math.round((new Date(until) - Date.now()) / 864e5);

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('417 re-runs cleanly', () => h.db.exec(MIG));
  const admin = await h.signup('admin@test.dev', 'admin');
  const user = await h.signup('u@test.dev', 'creator');
  const other = await h.signup('o@test.dev', 'other');
  const rando = await h.signup('r@test.dev', 'rando');
  await h.admin();
  await h.q(`insert into t417_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set users = array[$1, $2, $3]::uuid[] where key = 'creator_program'`, [user, other, rando]);
  await h.q(`update profiles set verified_as = 'YouTube · creator' where id = $1`, [user]);
  await h.q(`update profiles set verified_as = 'TikTok · other' where id = $1`, [other]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const prof = async (id) => (await h.q(`select badges, shown_badge, plus_until from profiles where id = $1`, [id]))[0];

  // Joining
  h.eq('unverified people can not apply', await call(rando, `select apply_creator(1500, 'https://youtube.com/watch?v=x', '')`), 'Get verified first');
  await h.q(`update feature_flags set users = array[$1, $2]::uuid[] where key = 'creator_program'`, [user, other]);
  h.eq('flag off means no', await call(rando, `select apply_creator(1500, 'https://youtube.com/watch?v=x', '')`), 'Not available yet');
  h.eq('bad link refused', String(await call(user, `select apply_creator(1500, 'youtube.com', '')`)).includes('content_link'), true);
  const rid = await call(user, `select apply_creator(1500, 'https://youtube.com/watch?v=x', 'hi')`);
  h.eq('a verified creator applies', typeof rid === 'string' && rid.length === 36, true);
  h.eq('one open application at a time', await call(user, `select apply_creator(1500, 'https://youtube.com/watch?v=y', '')`), 'You already have an application waiting for review');
  h.eq('content needs membership', await call(user, `select submit_creator_content('https://youtube.com/watch?v=c1', '')`), 'Join the Creator Program first');

  await h.as(user);
  h.eq('they see their own row', (await h.q(`select count(*)::int n from creator_applications`))[0].n, 1);
  await h.as(other);
  h.eq('others do not', (await h.q(`select count(*)::int n from creator_applications`))[0].n, 0);
  await h.admin();

  h.eq('non-admins can not review', await call(other, `select review_creator($1, true, 1, '')`, [rid]), 'Admins only');
  h.eq('approving needs a tier', await call(admin, `select review_creator($1, true, null, '')`, [rid]), 'Pick a tier');
  h.eq('rejecting needs a note', await call(admin, `select review_creator($1, false, null, '')`, [rid]), 'Say why, so they know what to change');
  h.eq('missing link is a readable error', await call(other, `select apply_creator(10, null, '')`), 'Add a link');

  await h.q(`update profiles set badges = '{bug_hunter,creator_1}', shown_badge = 'creator_1', plus_until = now() + interval '10 days' where id = $1`, [user]);
  h.eq('approve as tier 2', await call(admin, `select review_creator($1, true, 2, 'nice videos')`, [rid]), 'ok');
  let p = await prof(user);
  h.eq('tier 2 replaces tier 1, other badges stay', [...p.badges].sort(), ['bug_hunter', 'creator_2']);
  h.eq('shown badge follows', p.shown_badge, 'creator_2');
  h.eq('12 months Plus added on top of the 10 days left', daysLeft(p.plus_until) >= 381 && daysLeft(p.plus_until) <= 383, true);
  const row = (await h.q(`select status, tier, plus_months, review_note from creator_applications where id = $1`, [rid]))[0];
  h.eq('application row updated', [row.status, row.tier, row.plus_months, row.review_note], ['approved', 2, 12, 'nice videos']);
  h.eq('three log rows (program, badge, Plus)', (await h.q(`select action from mod_log where target_id = $1 order by id`, [user])).map((x) => x.action), ['creator_approved', 'badge_given', 'plus_gift']);
  h.eq('already reviewed', await call(admin, `select review_creator($1, true, 2, '')`, [rid]), 'Already reviewed');
  h.eq('a member can not apply again', await call(user, `select apply_creator(1500, 'https://youtube.com/watch?v=z', '')`), "You're already in the Creator Program");

  const rid2 = await call(other, `select apply_creator(200, 'https://tiktok.com/@other/video/1', '')`);
  h.eq('reject with a note', await call(admin, `select review_creator($1, false, null, 'Under 1k followers')`, [rid2]), 'ok');
  p = await prof(other);
  h.eq('nothing given on a rejection', [p.badges, p.plus_until], [[], null]);
  h.eq('30 day wait after a rejection', await call(other, `select apply_creator(2000, 'https://tiktok.com/@other/video/2', '')`), 'You can apply again 30 days after a rejection');
  await h.q(`update creator_applications set reviewed_at = now() - interval '31 days' where id = $1`, [rid2]);
  h.eq('...and then they can', typeof (await call(other, `select apply_creator(2000, 'https://tiktok.com/@other/video/2', '')`)), 'string');
  h.eq('tier 1 gets 3 months', await call(admin, `select review_creator((select id from creator_applications where user_id = $1 and status = 'pending'), true, 1, '')`, [other]), 'ok');
  p = await prof(other);
  h.eq('3 months from now', daysLeft(p.plus_until), 93);
  h.eq('creator_1 given', p.badges, ['creator_1']);

  // Content rewards
  const c1 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=c1', 'first one')`);
  h.eq('a member sends in a video', typeof c1 === 'string' && c1.length === 36, true);
  h.eq('same link only once', await call(user, `select submit_creator_content('https://YouTube.com/watch?v=c1', '')`), 'You already sent that link');
  await call(user, `select submit_creator_content('https://youtube.com/watch?v=c2', '')`);
  await call(user, `select submit_creator_content('https://youtube.com/watch?v=c3', '')`);
  h.eq('three waiting is the cap', await call(user, `select submit_creator_content('https://youtube.com/watch?v=c4', '')`), 'You have 3 waiting for review already. Wait for those first.');
  h.eq('non-admins can not review content', await call(other, `select review_creator_content($1, true, '')`, [c1]), 'Admins only');
  const before = daysLeft((await prof(user)).plus_until);
  h.eq('approve a piece', await call(admin, `select review_creator_content($1, true, '')`, [c1]), 'ok');
  h.eq('a month of Plus added', daysLeft((await prof(user)).plus_until) - before, 31);
  h.eq('already reviewed content', await call(admin, `select review_creator_content($1, true, '')`, [c1]), 'Already reviewed');
  h.eq('content log rows', (await h.q(`select action from mod_log where target_id = $1 and action like 'content_%' or (target_id = $1 and reason like '%content')`, [user])).map((x) => x.action), ['content_approved', 'plus_gift']);
  const c2 = (await h.q(`select id from creator_content where user_id = $1 and status = 'pending' order by created_at limit 1`, [user]))[0].id;
  h.eq('rejecting content needs a note', await call(admin, `select review_creator_content($1, false, '')`, [c2]), 'Say why, so they know what to change');
  h.eq('reject a piece', await call(admin, `select review_creator_content($1, false, 'Not about Yapper')`, [c2]), 'ok');
  h.eq('no Plus for a rejected one', daysLeft((await prof(user)).plus_until) - before, 31);
  h.eq('room for one more after two were reviewed', typeof (await call(user, `select submit_creator_content('https://youtube.com/watch?v=c4', '')`)), 'string');

  // Leaving
  h.eq('revoke is admin only', await call(other, `select revoke_creator($1, '')`, [user]), 'Admins only');
  h.eq('revoke needs a member', await call(admin, `select revoke_creator($1, 'x')`, [rando]), 'Not in the Creator Program');
  h.eq('revoke', await call(admin, `select revoke_creator($1, 'reuploads')`, [user]), 'ok');
  p = await prof(user);
  h.eq('badge gone, shown badge cleared, Plus stays', [p.badges, p.shown_badge, p.plus_until !== null], [['bug_hunter'], null, true]);
  h.eq('no more content once out', await call(user, `select submit_creator_content('https://youtube.com/watch?v=c5', '')`), 'Join the Creator Program first');
  h.eq('revoke logged', (await h.q(`select reason from mod_log where target_id = $1 and action = 'creator_revoked'`, [user]))[0].reason, 'reuploads');
  h.eq('flag row is in test mode', (await h.q(`select mode from feature_flags where key = 'creator_program'`))[0].mode, 'test');
}
