// 497: Creator Center v2: title/thumb on pieces, referral links with a Plus bonus, public leaderboard.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

const STANDINS = `
alter table auth.users add column if not exists email_confirmed_at timestamptz default now();
create table if not exists public.t417_admins (id uuid primary key);
create table if not exists public.t417_banned (id uuid primary key);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
alter table public.profiles add column if not exists verified_as text;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists verify_required boolean not null default false;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select exists (select 1 from public.t417_admins where id = auth.uid()) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.t417_banned where id = uid) $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and auth.uid() = any(users)) from public.feature_flags where key = k), false) $$;
create or replace function public.rt_profile_changed(uids uuid[]) returns void language sql as $$ select $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  for (const m of ['417_creator_program.sql', '418_creator_center.sql', '419_elite_500k.sql']) await h.db.exec(mig(m));
  await h.db.exec(mig('497_creator_center_v2.sql'));
  await h.ok('497 re-runs cleanly', () => h.db.exec(mig('497_creator_center_v2.sql')));
  const admin = await h.signup('admin@test.dev', 'admin');
  const user = await h.signup('u@test.dev', 'creator');
  const other = await h.signup('o@test.dev', 'other');
  const fans = [];
  for (let i = 0; i < 26; i++) fans.push(await h.signup(`fan${i}@test.dev`, `fan${i}`));
  await h.admin();
  await h.q(`insert into t417_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set users = array[$1]::uuid[] where key = 'creator_program'`, [user]);
  await h.q(`update profiles set verified_as = 'YouTube · creator', badges = '{creator_1}', shown_badge = 'creator_1' where id = $1`, [user]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];

  // Only one submit function is left
  h.eq('one submit_creator_content', Number(await one(`select count(*) from pg_proc where proname = 'submit_creator_content'`)), 1);
  const c0 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=old', '')`);
  h.eq('2-arg call still works', typeof c0 === 'string' && c0.length === 36, true);
  const c1 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=c1', 'n', 30000, 'My video about Yapin', 'https://i.ytimg.com/vi/c1/hqdefault.jpg')`);
  h.eq('5-arg call with title and thumb', typeof c1 === 'string' && c1.length === 36, true);
  let row = (await h.q(`select title, thumb from creator_content where id = $1`, [c1]))[0];
  h.eq('title and thumb stored', [row.title, row.thumb], ['My video about Yapin', 'https://i.ytimg.com/vi/c1/hqdefault.jpg']);
  h.eq('thumb from a random host refused', String(await call(user, `select submit_creator_content('https://youtube.com/watch?v=c2', '', 1, 't', 'https://evil.example/x.jpg')`)).includes('creator_content_thumb_host'), true);
  h.eq('http thumb refused', String(await call(user, `select submit_creator_content('https://youtube.com/watch?v=c3', '', 1, 't', 'http://i.ytimg.com/x.jpg')`)).includes('creator_content_thumb_host'), true);
  h.eq('look-alike host refused', String(await call(user, `select submit_creator_content('https://youtube.com/watch?v=c4', '', 1, 't', 'https://ytimg.com.evil.example/x.jpg')`)).includes('creator_content_thumb_host'), true);
  await call(admin, `select review_creator_content($1, false, 'old one', null)`, [c0]);
  h.eq('tiktok cdn ok', typeof (await call(user, `select submit_creator_content('https://tiktok.com/@me/video/5', '', 1, 't', 'https://p16-sign-va.tiktokcdn.com/obj/x.jpeg')`)) === 'string', true);
  h.eq('long title cut to 160', (await h.q(`select char_length(title) n from creator_content where id = $1`, [await call(user, `select submit_creator_content('https://youtube.com/watch?v=c6', '', 1, repeat('x', 300), null)`)]))[0].n, 160);

  // Referrals: service role only, username code, creator only, no self, once per account, confirmed accounts only
  h.eq("members can't record referrals", String(await call(other, `select record_creator_referral('creator', $1)`, [other])).includes('permission denied'), true);
  h.eq('unknown code: false, no error', await one(`select record_creator_referral('nobody', $1)`, [fans[0]]), false);
  h.eq('a non-creator username: false', await one(`select record_creator_referral('other', $1)`, [fans[0]]), false);
  h.eq('self: false', await one(`select record_creator_referral('creator', $1)`, [user]), false);
  await h.q(`update auth.users set email_confirmed_at = null where id = $1`, [fans[0]]);
  h.eq('a creator code records', await one(`select record_creator_referral('CREATOR', $1)`, [fans[0]]), true);
  h.eq('same account again: false', await one(`select record_creator_referral('creator', $1)`, [fans[0]]), false);
  let r0 = (await h.q(`select referrer, confirmed_at, seq from creator_referrals where user_id = $1`, [fans[0]]))[0];
  h.eq('row has the referrer, not confirmed yet', [r0.referrer, r0.confirmed_at, r0.seq], [user, null, null]);
  await h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [fans[0]]);
  r0 = (await h.q(`select confirmed_at, seq from creator_referrals where user_id = $1`, [fans[0]]))[0];
  h.eq('email confirmed: counted as #1', [r0.confirmed_at !== null, r0.seq], [true, 1]);
  h.eq('creator sees own referrals', Number(await call(user, `select count(*) from creator_referrals`)), 1);
  h.eq('others see none', Number(await call(other, `select count(*) from creator_referrals`)), 0);
  const plusBefore = (await h.q(`select plus_until from profiles where id = $1`, [user]))[0].plus_until;
  for (let i = 1; i < 24; i++) await h.q(`select record_creator_referral('creator', $1)`, [fans[i]]);
  h.eq('24 confirmed sign-ups: no Plus yet', String((await h.q(`select plus_until from profiles where id = $1`, [user]))[0].plus_until), String(plusBefore));
  await h.q(`update profiles set verify_required = true where id = $1`, [fans[24]]);
  h.eq('a flagged account records', await one(`select record_creator_referral('creator', $1)`, [fans[24]]), true);
  h.eq('but is not counted', (await h.q(`select seq from creator_referrals where user_id = $1`, [fans[24]]))[0].seq, null);
  h.eq('still no Plus', String((await h.q(`select plus_until from profiles where id = $1`, [user]))[0].plus_until), String(plusBefore));
  await h.q(`select record_creator_referral('creator', $1)`, [fans[25]]);
  const p = (await h.q(`select plus_until from profiles where id = $1`, [user]))[0];
  h.eq('25th confirmed sign-up: a month of Plus', Math.round((new Date(p.plus_until) - Date.now()) / 864e5), 31);
  h.eq('logged as plus_gift with no actor', (await h.q(`select actor, reason from mod_log where target_id = $1 and action = 'plus_gift' order by id desc limit 1`, [user]))[0].reason.includes('25 sign-ups'), true);
  // Delete one, add one: the counter never goes back, so no second payout
  await h.q(`delete from profiles where id = $1`, [fans[3]]);
  const extra = await h.signup('extra@test.dev', 'extra');
  await h.admin();
  await h.q(`select record_creator_referral('creator', $1)`, [extra]);
  h.eq('after a delete + a new one: #26, no second month', [(await h.q(`select seq from creator_referrals where user_id = $1`, [extra]))[0].seq, String((await h.q(`select plus_until from profiles where id = $1`, [user]))[0].plus_until)], [26, String(p.plus_until)]);
  await h.q(`insert into t417_banned values ($1)`, [user]);
  const extra2 = await h.signup('extra2@test.dev', 'extra2');
  await h.admin();
  h.eq('banned creator: false', await one(`select record_creator_referral('creator', $1)`, [extra2]), false);
  await h.q(`delete from t417_banned where id = $1`, [user]);

  // Leaderboard
  await h.q(`update profiles set badges = '{creator_2}' where id = $1`, [other]);
  await h.q(`update feature_flags set users = array[$1, $2]::uuid[] where key = 'creator_program'`, [user, other]);
  const o1 = await call(other, `select submit_creator_content('https://youtube.com/watch?v=o1', '', 200000)`);
  await call(admin, `select review_creator_content($1, true, '', null)`, [c1]);
  await call(admin, `select review_creator_content($1, true, '', null)`, [o1]);
  await h.as(user);
  let lb = await h.q(`select * from creator_leaderboard()`);
  await h.admin();
  h.eq('two creators, biggest first', lb.map((r) => [r.username, Number(r.views), r.pieces, r.tier]), [['other', 200000, 1, 2], ['creator', 30000, 1, 1]]);
  await h.as(null);
  lb = await h.q(`select username from creator_leaderboard()`);
  h.eq('flag in test: anon sees nothing', lb.length, 0);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'creator_program'`);
  await h.as(null);
  lb = await h.q(`select username from creator_leaderboard()`);
  h.eq('flag everyone: anon can read it', lb.length, 2);
  await h.admin();
  h.eq('the badge filter uses its partial index', (await h.q(`explain select 1 from profiles p where p.badges && array['creator_1', 'creator_2', 'creator_3']`)).some((r) => /profiles_creator_badge_idx/.test(Object.values(r)[0])), true);
  await h.q(`insert into t417_banned values ($1)`, [other]);
  await h.as(user);
  h.eq('banned creators drop off', (await h.q(`select username from creator_leaderboard()`)).map((r) => r.username), ['creator']);
  await h.admin();
}
