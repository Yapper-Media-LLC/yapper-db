// 518: Creator Program v3: one payout per video (video_key), staff set format + views, 1k followers to apply,
// stable invite codes, invites count only real accounts (7 days, active on 3, not on the creator's device).
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
create table if not exists public.t518_shared (a uuid, b uuid);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
alter table public.profiles add column if not exists verified_as text;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists verify_required boolean not null default false;
alter table public.profiles add column if not exists created_at timestamptz not null default now();
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.shard_days (user_id uuid, day date, minutes int not null default 0, primary key (user_id, day));
create table if not exists public.shard_wallets (user_id uuid primary key, frozen boolean not null default false);
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select exists (select 1 from public.t417_admins where id = auth.uid()) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.t417_banned where id = uid) $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and auth.uid() = any(users)) from public.feature_flags where key = k), false) $$;
create or replace function public.rt_profile_changed(uids uuid[]) returns void language sql as $$ select $$;
create or replace function public.shard_is_bot(uid uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.profiles where id = uid and 'bot' = any(badges)) $$;
create or replace function public.shard_shared_device(a uuid, b uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.t518_shared s where (s.a = $1 and s.b = $2) or (s.a = $2 and s.b = $1)) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  for (const m of ['417_creator_program.sql', '418_creator_center.sql', '419_elite_500k.sql', '497_creator_center_v2.sql']) await h.db.exec(mig(m));
  await h.db.exec(mig('518_creator_v3.sql'));
  await h.ok('518 re-runs cleanly', () => h.db.exec(mig('518_creator_v3.sql')));
  const admin = await h.signup('admin@test.dev', 'admin');
  const user = await h.signup('u@test.dev', 'creator');
  const other = await h.signup('o@test.dev', 'other');
  const applicant = await h.signup('a@test.dev', 'applicant');
  await h.admin();
  await h.q(`insert into t417_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set users = array[$1, $2, $3]::uuid[] where key = 'creator_program'`, [user, other, applicant]);
  await h.q(`update profiles set verified_as = 'YouTube · x', badges = '{creator_1}', shown_badge = 'creator_1' where id = any($1::uuid[])`, [[user, other]]);
  await h.q(`update profiles set verified_as = 'YouTube · applicant' where id = $1`, [applicant]);
  await h.ok('518 re-runs with creators in place (backfills their codes)', () => h.db.exec(mig('518_creator_v3.sql')));
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];
  const key = (l) => one(`select creator_video_key($1)`, [l]);

  // 1. video_key: one id however the link is written
  const yt = ['https://youtu.be/dQw4w9WgXcQ?si=abc', 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30', 'https://m.youtube.com/shorts/dQw4w9WgXcQ',
    'https://youtube.com/live/dQw4w9WgXcQ?feature=share', 'https://www.youtube.com/watch?feature=x&v=dQw4w9WgXcQ', 'https://music.youtube.com/watch?v=dQw4w9WgXcQ'];
  h.eq('every YouTube form is one key', [...new Set(await Promise.all(yt.map(key)))], ['yt:dQw4w9WgXcQ']);
  h.eq('YouTube ids keep their case', await key('https://youtu.be/AbCdEfGhIjK'), 'yt:AbCdEfGhIjK');
  h.eq('TikTok by video id', [await key('https://www.tiktok.com/@me/video/7300000000000000001?lang=en'), await key('https://m.tiktok.com/v/7300000000000000001')], ['tt:7300000000000000001', 'tt:7300000000000000001']);
  h.eq('X and Twitter are one', [await key('https://x.com/me/status/1234567890'), await key('https://twitter.com/Me/status/1234567890?s=20')], ['x:1234567890', 'x:1234567890']);
  h.eq('Instagram reel / p', [await key('https://www.instagram.com/reel/Cxyz123/?igsh=1'), await key('https://instagram.com/p/Cxyz123')], ['ig:Cxyz123', 'ig:Cxyz123']);
  h.eq('Twitch video and clip', [await key('https://www.twitch.tv/videos/123456'), await key('https://clips.twitch.tv/FunnyClip-abc')], ['twv:123456', 'twc:FunnyClip-abc']);
  h.eq('anything else: host + path, no www, fragment or trailing slash', await key('https://www.Example.com/Blog/Post/#top'), 'web:example.com/blog/post');
  h.eq('nocookie and :443 are the same YouTube video', [await key('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ'), await key('https://youtube.com:443/watch?v=dQw4w9WgXcQ')], ['yt:dQw4w9WgXcQ', 'yt:dQw4w9WgXcQ']);
  h.eq('X i/web and fxtwitter forms', [await key('https://x.com/i/web/status/1234567890'), await key('https://fxtwitter.com/me/status/1234567890')], ['x:1234567890', 'x:1234567890']);

  // 2. submit: once per video, across everyone
  const c1 = await call(user, `select submit_creator_content('https://youtu.be/dQw4w9WgXcQ?si=1', '', 30000)`);
  h.eq('a piece goes in', typeof c1 === 'string' && c1.length === 36, true);
  h.eq('same video, other form, same person: refused', await call(user, `select submit_creator_content('https://www.youtube.com/watch?v=dQw4w9WgXcQ', '', 1)`), 'You already sent that one');
  h.eq('same video, someone else: refused', await call(other, `select submit_creator_content('https://m.youtube.com/shorts/dQw4w9WgXcQ', '', 1)`), 'Someone already sent that one in');
  h.eq('TikTok short link refused', String(await call(user, `select submit_creator_content('https://vm.tiktok.com/ZMabc/', '', 1)`)).startsWith('Open the TikTok'), true);
  h.eq('a login part before the host refused', await call(user, `select submit_creator_content('https://yt:x@www.youtube.com/watch?v=dQw4w9WgXcQ', '', 1)`), "That link doesn't look right");
  h.eq('a trailing dot on the host refused', await call(user, `select submit_creator_content('https://www.youtube.com./watch?v=dQw4w9WgXcQ', '', 1)`), "That link doesn't look right");
  h.eq('an odd YouTube form with no id refused', await call(user, `select submit_creator_content('https://www.youtube.com/attribution_link?u=%2Fwatch', '', 1)`), 'Paste the normal link to the video or post');
  h.eq('the unique index holds even past the function', String(await h.q(`insert into creator_content (user_id, link, video_key) values ($1, 'https://youtu.be/dQw4w9WgXcQ', 'yt:dQw4w9WgXcQ')`, [other]).catch((e) => e.message)).includes('creator_content_video_once'), true);
  const c2 = await call(user, `select submit_creator_content('https://youtube.com/watch?v=shortvideo1', '', 30000, 't', null, 'short')`);
  h.eq('creator can mark their own piece short', await one(`select format from creator_content where id = $1`, [c2]), 'short');
  const c3 = await call(user, `select submit_creator_content('https://www.tiktok.com/@me/video/7300000000000000009', '', 30000, '', null, 'long')`);
  h.eq('"long" never lifts a TikTok to long-form', await one(`select format from creator_content where id = $1`, [c3]), 'short');
  h.eq('3 waiting is still the cap', await call(user, `select submit_creator_content('https://youtube.com/watch?v=fourthvideo', '', 1)`), 'You have 3 waiting for review already. Wait for those first.');

  // 3. review: views required, staff set the format, checks kept
  h.eq('approve without views: refused', await call(admin, `select review_creator_content($1, true, '', null)`, [c1]), 'Type the views you see on the link');
  h.eq('bad format refused', await call(admin, `select review_creator_content($1, true, '', 30000, 'medium')`, [c1]), 'Format is long or short');
  h.eq('members can not review', await call(user, `select review_creator_content($1, true, '', 30000)`, [c1]), 'Admins only');
  await call(admin, `select review_creator_content($1, true, '', 30000, 'short', '{"fetched": 30000, "channel": "match", "short": true}'::jsonb)`, [c1]);
  let row = (await h.q(`select status, format, views_checked, reward_months, review_checks from creator_content where id = $1`, [c1]))[0];
  h.eq('a Short sent as a link: paid on the short scale', [row.status, row.format, row.views_checked, row.reward_months], ['approved', 'short', 30000, 1]);
  h.eq('checks kept on the row', row.review_checks.channel, 'match');
  await call(admin, `select review_creator_content($1, true, '', 30000, null, '[1,2]'::jsonb)`, [c2]);
  h.eq('format null keeps it; non-object checks dropped', [await one(`select format from creator_content where id = $1`, [c2]), await one(`select review_checks from creator_content where id = $1`, [c2])], ['short', null]);
  await call(admin, `select review_creator_content($1, false, 'Not about Yapin')`, [c3]);
  const again = await call(other, `select submit_creator_content('https://tiktok.com/@me/video/7300000000000000009', '', 5)`);
  h.eq('a rejected video can be sent by someone else', typeof again === 'string' && again.length === 36, true);

  // 4. apply_creator: 1,000+ followers
  h.eq('under 1k refused', await call(applicant, `select apply_creator(999, 'https://youtube.com/@applicant')`), 'You need 1,000+ followers or subscribers to join');
  const app = await call(applicant, `select apply_creator(1000, 'https://youtube.com/@applicant')`);
  h.eq('1k is enough', typeof app === 'string' && app.length === 36, true);

  // 5. invite codes
  h.eq('members can not read creator_links', String(await call(user, `select count(*) from creator_links`)).includes('permission denied'), true);
  h.eq('existing creators got a code', (await h.q(`select code from creator_links where user_id = $1`, [user]))[0]?.code, 'creator');
  await call(admin, `select review_creator($1, true, 1, '')`, [app]);
  h.eq('approval gives a code', (await h.q(`select code from creator_links where user_id = $1`, [applicant]))[0]?.code, 'applicant');
  h.eq('joining gives the badge, no Plus', [await one(`select badges from profiles where id = $1`, [applicant]), await one(`select plus_until from profiles where id = $1`, [applicant]), Number(await one(`select count(*) from mod_log where target_id = $1 and action = 'plus_gift'`, [applicant]))], [['creator_1'], null, 0]);
  await h.q(`update profiles set username = 'creator_renamed' where id = $1`, [user]);
  const squatter = await h.signup('s@test.dev', 'creator');
  await h.admin();
  await h.q(`update profiles set badges = '{creator_1}' where id = $1`, [squatter]);
  await h.q(`select creator_link_code($1)`, [squatter]);
  h.eq('a freed username gets a different code', /^creator\d{3}$/.test((await h.q(`select code from creator_links where user_id = $1`, [squatter]))[0].code), true);
  const fan0 = await h.signup('f0@test.dev', 'fan0');
  await h.admin();
  h.eq('old code still points at the renamed creator', [await one(`select record_creator_referral('Creator', $1)`, [fan0]), await one(`select referrer from creator_referrals where user_id = $1`, [fan0])], [true, user]);
  const fanX = await h.signup('fx@test.dev', 'fanx');
  await h.admin();
  h.eq('the new username is not a code', await one(`select record_creator_referral('creator_renamed', $1)`, [fanX]), false);
  h.eq('creators can not read referral rows (no refusal reasons)', String(await call(user, `select count(*) from creator_referrals`)).includes('permission denied'), true);
  h.eq('members can not record referrals', String(await call(other, `select record_creator_referral('creator', $1)`, [other])).includes('permission denied'), true);

  // 6. invites count only real accounts
  h.eq('recorded as pending, not counted', (await h.q(`select status, seq from creator_referrals where user_id = $1`, [fan0]))[0], { status: 'pending', seq: null });
  const settle = async () => {
    await h.q(`update creator_links set settled_at = null where user_id = $1`, [user]);
    await h.q(`update creator_referrals set checked_at = null where referrer = $1`, [user]);
    return call(user, `select creator_referrals_settle()`);
  };
  const old = async (uid, days = 3) => {
    await h.q(`update profiles set created_at = now() - interval '8 days' where id = $1`, [uid]);
    await h.q(`update creator_referrals set created_at = now() - interval '8 days' where user_id = $1`, [uid]);
    for (let d = 0; d < days; d++) await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - $2::int, 5) on conflict (user_id, day) do update set minutes = 5`, [uid, d]);
  };
  let s = await settle();
  h.eq('a day-old account waits', [s.counted, s.waiting, s.code], [0, 1, 'creator']);
  await h.q(`update profiles set created_at = now() - interval '8 days' where id = $1`, [fan0]);
  await h.q(`update creator_referrals set created_at = now() - interval '8 days' where user_id = $1`, [fan0]);
  await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date, 5), ($1, current_date - 1, 0)`, [fan0]);
  s = await settle();
  h.eq('old but active on 1 day: waits', [s.counted, s.waiting], [0, 1]);
  await h.q(`update auth.users set email_confirmed_at = null where id = $1`, [fan0]);
  await old(fan0);
  s = await settle();
  h.eq('unconfirmed email: waits', s.counted, 0);
  await h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [fan0]);
  h.eq('the email-confirm trigger counts nothing now', (await h.q(`select status from creator_referrals where user_id = $1`, [fan0]))[0].status, 'pending');
  s = await settle();
  h.eq('7 days, 3 active days, confirmed: counted as #1', [s.counted, s.waiting, s.top_seq, await one(`select seq from creator_referrals where user_id = $1`, [fan0])], [1, 0, 1, 1]);

  const refused = async (setup, reason) => {
    const f = await h.signup(`${reason.replace(/\W/g, '')}@test.dev`, reason.replace(/\W/g, '').slice(0, 20));
    await h.admin();
    await h.q(`select record_creator_referral('creator', $1)`, [f]);
    await old(f);
    await setup(f);
    await settle();
    return (await h.q(`select status, reason from creator_referrals where user_id = $1`, [f]))[0];
  };
  h.eq('same device or network: refused', await refused((f) => h.q(`insert into t518_shared values ($1, $2)`, [user, f]), 'samedevice'), { status: 'refused', reason: 'same device or network' });
  h.eq('flagged at sign-up: waits (it clears when they confirm)', await refused((f) => h.q(`update profiles set verify_required = true where id = $1`, [f]), 'flagged'), { status: 'pending', reason: null });
  h.eq('bot: refused', await refused((f) => h.q(`update profiles set badges = '{bot}' where id = $1`, [f]), 'botty'), { status: 'refused', reason: 'bot' });
  h.eq('banned: waits (bans can be lifted)', await refused((f) => h.q(`insert into t417_banned values ($1)`, [f]), 'bannedfan'), { status: 'pending', reason: null });
  h.eq('Shards-frozen: waits', await refused((f) => h.q(`insert into shard_wallets values ($1, true)`, [f]), 'frozenfan'), { status: 'pending', reason: null });
  h.eq('a minute a day is not active', await refused((f) => h.q(`update shard_days set minutes = 1 where user_id = $1`, [f]), 'idlefan'), { status: 'pending', reason: null });
  h.eq('still waiting 60 days on: refused for good', await refused(async (f) => { await h.q(`update creator_referrals set created_at = now() - interval '61 days' where user_id = $1`, [f]); await h.q(`update auth.users set email_confirmed_at = null where id = $1`, [f]); }, 'oldfan'), { status: 'refused', reason: 'never counted' });
  // Waiting rows don't block newer ones: checked ones go to the back for an hour
  const waitingChecked = Number(await one(`select count(*) from creator_referrals where referrer = $1 and status = 'pending' and checked_at is not null`, [user]));
  h.eq('waiting rows got checked_at', waitingChecked >= 3, true);

  // At most once a minute: a second call right away doesn't check anything
  const late = await h.signup('late@test.dev', 'late');
  await h.admin();
  await h.q(`select record_creator_referral('creator', $1)`, [late]);
  await old(late);
  s = await call(user, `select creator_referrals_settle()`);
  h.eq('second settle within a minute: nothing checked (late + 4 waiting)', [s.counted, s.waiting], [1, 5]);

  // 25 counted = a month of Plus, once
  const plusBefore = await one(`select plus_until from profiles where id = $1`, [user]);
  const fans = [];
  for (let i = 0; i < 24; i++) {
    const f = await h.signup(`n${i}@test.dev`, `n${i}`);
    fans.push(f);
    await h.admin();
    await h.q(`select record_creator_referral('creator', $1)`, [f]);
    await old(f);
  }
  s = await settle();
  h.eq('fan0 + late + 24 more = 26 counted', [s.counted, s.top_seq], [26, 26]);
  const p = await one(`select plus_until from profiles where id = $1`, [user]);
  h.eq('the 25th pays a month', Math.round((new Date(p) - new Date(plusBefore ?? Date.now())) / 864e5), 31);
  h.eq('logged as plus_gift', (await h.q(`select reason from mod_log where target_id = $1 and action = 'plus_gift' order by id desc limit 1`, [user]))[0].reason.includes('25 sign-ups'), true);
  // Deleting counted accounts never lets a step pay again (the counter lives on creator_links)
  await h.q(`delete from profiles where id = any($1::uuid[])`, [[fans[22], fans[23]]]);
  const again2 = await h.signup('again@test.dev', 'againfan');
  await h.admin();
  await h.q(`select record_creator_referral('creator', $1)`, [again2]);
  await old(again2);
  s = await settle();
  h.eq('after 2 deletes + 1 new: #27, still one payout', [s.top_seq, await one(`select seq from creator_referrals where user_id = $1`, [again2]), Number(await one(`select count(*) from mod_log where target_id = $1 and action = 'plus_gift' and reason like '%sign-ups%'`, [user]))], [27, 27, 1]);
  h.eq('the late one counted too', (await h.q(`select status from creator_referrals where user_id = $1`, [late]))[0].status, 'counted');

  // Who can call settle
  const nc = await h.signup('nc@test.dev', 'nc');
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'creator_program'`, [nc]);
  h.eq('non-creators get null', await call(nc, `select creator_referrals_settle()`), 'ok');
  h.eq('anon can not call settle', String(await call(null, `select creator_referrals_settle()`)).includes('permission denied'), true);
  h.eq('one submit and one review function', [Number(await one(`select count(*) from pg_proc where proname = 'submit_creator_content'`)), Number(await one(`select count(*) from pg_proc where proname = 'review_creator_content'`))], [1, 1]);
}
