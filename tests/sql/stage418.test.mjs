// 418 + 419: Creator Center: rewards by views (two scales), views checked by staff, badge tiers that follow the total.
// Starts from stage 24 with the same stand-ins as 417, runs 417 then 418.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

const STANDINS = `
create table if not exists public.t417_admins (id uuid primary key);
create table if not exists public.t417_banned (id uuid primary key);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
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
  await h.db.exec(mig('417_creator_program.sql'));
  await h.db.exec(mig('418_creator_center.sql'));
  await h.ok('418 re-runs cleanly', () => h.db.exec(mig('418_creator_center.sql')));
  await h.db.exec(mig('419_elite_500k.sql'));
  await h.ok('419 re-runs cleanly', () => h.db.exec(mig('419_elite_500k.sql')));
  const admin = await h.signup('admin@test.dev', 'admin');
  const user = await h.signup('u@test.dev', 'creator');
  await h.admin();
  await h.q(`insert into t417_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set users = array[$1]::uuid[] where key = 'creator_program'`, [user]);
  await h.q(`update profiles set verified_as = 'YouTube · creator', badges = '{creator_1}', shown_badge = 'creator_1' where id = $1`, [user]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const prof = async (id) => (await h.q(`select badges, shown_badge, plus_until from profiles where id = $1`, [id]))[0];
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];

  // The ladder
  h.eq('format: youtube video is long', await one(`select creator_format_for('https://www.youtube.com/watch?v=abc')`), 'long');
  h.eq('format: shorts are short', await one(`select creator_format_for('https://youtube.com/shorts/abc')`), 'short');
  h.eq('format: tiktok is short', await one(`select creator_format_for('https://www.tiktok.com/@me/video/1')`), 'short');
  h.eq('format: x.com is short', await one(`select creator_format_for('https://x.com/me/status/1')`), 'short');
  h.eq('format: twitch is long', await one(`select creator_format_for('https://twitch.tv/videos/1')`), 'long');
  h.eq('long 4,999 views: nothing', await one(`select creator_reward_months('long', 4999)`), 0);
  h.eq('long 5k: 1 month', await one(`select creator_reward_months('long', 5000)`), 1);
  h.eq('long 25k: 3', await one(`select creator_reward_months('long', 25000)`), 3);
  h.eq('long 100k: 6', await one(`select creator_reward_months('long', 100000)`), 6);
  h.eq('long 500k: 12', await one(`select creator_reward_months('long', 500000)`), 12);
  h.eq('short 24,999: nothing', await one(`select creator_reward_months('short', 24999)`), 0);
  h.eq('short 25k: 1 month', await one(`select creator_reward_months('short', 25000)`), 1);
  h.eq('short 2.5M: 12', await one(`select creator_reward_months('short', 2500000)`), 12);

  // Sending in
  const c0 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=old', '')`);
  h.eq('views default to 0 when left out', typeof c0 === 'string' && (await h.q(`select views from creator_content where id = $1`, [c0]))[0].views === 0, true);
  h.eq('negative views refused', await call(user, `select submit_creator_content('https://youtube.com/watch?v=n', '', -1)`), 'How many views does it have?');
  const c1 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=c1', 'first', 30000)`);
  h.eq('a member sends in a video with views', typeof c1 === 'string' && c1.length === 36, true);
  let row = (await h.q(`select format, views, views_checked from creator_content where id = $1`, [c1]))[0];
  h.eq('format and views stored', [row.format, row.views, row.views_checked], ['long', 30000, null]);
  const c2 = await call(user, `select submit_creator_content('https://tiktok.com/@me/video/2', '', 900000)`);
  h.eq('a tiktok is short-form', (await h.q(`select format from creator_content where id = $1`, [c2]))[0].format, 'short');

  // Review with the views staff saw
  h.eq('review without the views argument still works', await call(admin, `select review_creator_content($1, false, 'rejected the old one')`, [c0]), 'ok');
  const before = (await prof(user)).plus_until;
  h.eq('approve at what they said (30k long = 3 months)', await call(admin, `select review_creator_content($1, true, '', null)`, [c1]), 'ok');
  row = (await h.q(`select views_checked, reward_months, status from creator_content where id = $1`, [c1]))[0];
  h.eq('views_checked = reported, 3 months', [row.views_checked, row.reward_months, row.status], [30000, 3, 'approved']);
  h.eq('3 months of Plus', before === null ? daysLeft((await prof(user)).plus_until) : -1, 93);
  h.eq('no badge move yet (30k < 100k)', (await prof(user)).badges, ['creator_1']);

  h.eq('approve the tiktok at the views seen (400k short = 80k eq = 3 months)', await call(admin, `select review_creator_content($1, true, 'nice', 400000)`, [c2]), 'ok');
  row = (await h.q(`select views_checked, reward_months from creator_content where id = $1`, [c2]))[0];
  h.eq('staff count wins, 3 months', [row.views_checked, row.reward_months], [400000, 3]);
  h.eq('total views: 30k + 80k', Number(await one(`select creator_total_views($1)`, [user])), 110000);
  let p = await prof(user);
  h.eq('110k total: Pro Creator badge, shown badge follows', [p.badges, p.shown_badge], [['creator_2'], 'creator_2']);
  h.eq('badge_given logged with the total', (await h.q(`select reason from mod_log where target_id = $1 and action = 'badge_given' order by id desc limit 1`, [user]))[0].reason.startsWith('creator_2 (Creator Program: 110000'), true);

  // Under the first step: approved, counted, no Plus
  const c3 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=c3', '', 1200)`);
  const plusBefore = (await prof(user)).plus_until;
  h.eq('approve a small one', await call(admin, `select review_creator_content($1, true, '', null)`, [c3]), 'ok');
  h.eq('no Plus for it', String((await prof(user)).plus_until), String(plusBefore));
  h.eq('but reward row says 0 and approved', (await h.q(`select reward_months, status from creator_content where id = $1`, [c3]))[0].reward_months, 0);
  h.eq('no plus_gift row for it', (await h.q(`select count(*)::int n from mod_log where target_id = $1 and action = 'plus_gift'`, [user]))[0].n, 2);

  // Elite at 1M, with the Partner badge
  const c4 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=c4', '', 1)`);
  h.eq('approve a big one (900k long = 12 months)', await call(admin, `select review_creator_content($1, true, '', 900000)`, [c4]), 'ok');
  p = await prof(user);
  h.eq('1.01M total (past 500k): Elite + Partner', [...p.badges].sort(), ['creator_3', 'partner']);
  h.eq('shown badge is Elite', p.shown_badge, 'creator_3');
  h.eq('12 more months', daysLeft(p.plus_until), 93 + 93 + 372);

  // Never down, and a rejection changes nothing
  const c5 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=c5', '', 10)`);
  h.eq('reject needs a note', await call(admin, `select review_creator_content($1, false, '', null)`, [c5]), 'Say why, so they know what to change');
  h.eq('reject', await call(admin, `select review_creator_content($1, false, 'not about Yapin', null)`, [c5]), 'ok');
  p = await prof(user);
  h.eq('badges untouched by a rejection', [...p.badges].sort(), ['creator_3', 'partner']);
  h.eq('already reviewed', await call(admin, `select review_creator_content($1, true, '', null)`, [c5]), 'Already reviewed');
  h.eq('total views is not callable by members', String(await call(user, `select creator_total_views($1)`, [user])).includes('permission denied'), true);
  const c6 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=c6', '', 50000)`);
  await h.q(`update profiles set badges = '{}', shown_badge = null where id = $1`, [user]);
  h.eq('revoked creators get nothing for pending pieces', await call(admin, `select review_creator_content($1, true, '', null)`, [c6]), 'Not in the Creator Program any more');
}
