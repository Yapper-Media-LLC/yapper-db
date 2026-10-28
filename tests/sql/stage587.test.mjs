// 587: captcha on DMs. Starts from stage 24 (DMs from 001, friends from 007) plus the flags tables (031/041) and
// dm_requests (056), with stand-ins for the later bits get_or_create_dm calls (standing_guard, is_staff).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '054_dms_without_friending.sql', '056_dm_requests.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '587_dm_captcha.sql'), 'utf8');

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid()) or exists (select 1 from public.site_admins where user_id = auth.uid());
$$;
create schema if not exists realtime;
create or replace function realtime.broadcast_changes(topic text, event text, op text, tbl text, sch text, n record, o record) returns void language plpgsql as $$ begin return; end; $$;
create table if not exists public.t587_bots (user_id uuid primary key);
create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.t587_bots where user_id = uid); $$;
create table if not exists public.t587_limited (user_id uuid primary key);
create or replace function public.standing_guard(p_action text, p_server uuid, p_other uuid) returns void language plpgsql as $$ begin if exists (select 1 from public.t587_limited where user_id = auth.uid()) then raise exception 'Your account is limited'; end if; end; $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('587 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag dm_captcha is in test mode', (await h.one(`select mode from feature_flags where key = 'dm_captcha'`)).mode, 'test');

  const ann = await h.signup('ann@test.dev', 'ann');
  const others = [];
  for (const n of ['bob', 'cat', 'dan', 'eve', 'fay', 'gus']) others.push(await h.signup(`${n}@test.dev`, n));
  const [bob, cat, dan, eve, fay, gus] = others;
  const staff = await h.signup('staff@test.dev', 'staff');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 days', dms_from = 'everyone'`);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted')`, [ann, gus]);

  const open = async (who, other) => { await h.as(who); return (await h.one(`select get_or_create_dm($1) id`, [other])).id; };
  const refused = async (who, other) => { await h.as(who); let m = ''; try { await h.q(`select get_or_create_dm($1)`, [other]); } catch (e) { m = e.message; } return m; };

  // Flag off: no limit at all.
  await open(ann, bob); await open(ann, cat); await open(ann, dan);
  h.eq('flag off: 4th new person opens fine', typeof (await open(ann, eve)), 'string');
  await h.admin();
  h.eq('flag off: nothing logged', (await h.one(`select count(*)::int n from dm_open_log`)).n, 0);
  await h.admin();
  await h.q(`delete from channel_members`); await h.q(`delete from channels`);

  // Flag on for ann.
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'dm_captcha'`, [ann]);
  await open(ann, bob); await open(ann, cat); await open(ann, dan);
  await h.admin();
  h.eq('3 new people logged', (await h.one(`select count(distinct target)::int n from dm_open_log where user_id = $1`, [ann])).n, 3);
  h.eq('reopening an existing chat is free', typeof (await open(ann, bob)), 'string');
  h.eq('a friend is free', typeof (await open(ann, gus)), 'string');
  const m = await refused(ann, eve);
  h.eq('4th new person in 10 minutes: bot check', /^captcha:/.test(m), true);
  await h.admin();
  h.eq('still no chat with eve', (await h.one(`select count(*)::int n from channels where dm_key = $1`, [[ann, eve].sort().join(':')])).n, 0);
  // The API route wrote a pass after Cloudflare said yes.
  await h.admin();
  await h.q(`insert into dm_captcha_passes (user_id, until) values ($1, now() + interval '5 minutes')`, [ann]);
  h.eq('with a pass: eve opens', typeof (await open(ann, eve)), 'string');
  await h.admin();
  h.eq('the pass is used up', (await h.one(`select count(*)::int n from dm_captcha_passes where user_id = $1`, [ann])).n, 0);
  h.eq('5th new person: bot check again (until the 10 minutes are up)', /^captcha:/.test(await refused(ann, fay)), true);
  await h.admin();
  await h.q(`insert into dm_captcha_passes (user_id, until) values ($1, now() - interval '1 minute')`, [ann]);
  h.eq('an expired pass does not count', /^captcha:/.test(await refused(ann, fay)), true);
  // Cooldown over.
  await h.admin();
  await h.q(`update dm_open_log set created_at = now() - interval '11 minutes' where user_id = $1`, [ann]);
  h.eq('after 10 minutes: free again', typeof (await open(ann, fay)), 'string');
  // Refused-by-privacy attempts count too (message request spam).
  await h.admin();
  await h.q(`update profiles set dms_from = 'friends' where id = $1`, [staff]);
  await h.q(`delete from dm_open_log`);
  for (const o of [bob, cat, dan]) await h.q(`delete from channels where dm_key = $1`, [[ann, o].sort().join(':')]);
  await refused(ann, staff); // 'They only take messages from friends'
  await h.as(ann); await h.q(`select note_dm_request($1)`, [staff]);
  await h.admin();
  h.eq('message request recorded (0 rows ever before 587)', (await h.one(`select count(*)::int n from dm_requests where from_id = $1 and to_id = $2`, [ann, staff])).n, 1);
  await h.as(ann); await h.q(`select note_dm_request($1)`, [staff]);
  await h.admin();
  h.eq('noting twice is one row and one log row', (await h.one(`select (select count(*) from dm_requests where from_id = $1)::int + (select count(*) from dm_open_log where user_id = $1 and target = $2)::int n`, [ann, staff])).n, 2);
  await open(ann, bob); await open(ann, cat);
  h.eq('the refused attempt counted: next new person needs the check', /^captcha:/.test(await refused(ann, dan)), true);
  await h.admin(); await h.q(`update profiles set dms_from = 'friends' where id = $1`, [dan]);
  h.eq('note_dm_request on its own runs the check too', /^captcha:/.test(await (async () => { await h.as(ann); try { await h.q(`select note_dm_request($1)`, [dan]); return ''; } catch (e) { return e.message; } })()), true);
  await h.as(ann); await h.q(`select note_dm_request($1)`, [bob]);
  await h.admin();
  h.eq('noting someone who takes DMs records nothing', (await h.one(`select count(*)::int n from dm_requests where to_id = $1`, [bob])).n, 0);
  // Staff never see it.
  await h.q(`update feature_flags set mode = 'everyone' where key = 'dm_captcha'`);
  for (const o of [bob, cat, dan, eve]) await open(staff, o);
  h.eq('staff: no limit', typeof (await open(staff, fay)), 'string');
  // Bots open DMs as their own user and can never be friends: no bot check for them.
  const bot = await h.signup('bot@test.dev', 'bot');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 days' where id = $1`, [bot]);
  await h.q(`insert into t587_bots (user_id) values ($1)`, [bot]);
  for (const o of [ann, cat, bob, fay]) await open(bot, o);
  h.eq('bot: no limit', typeof (await open(bot, eve)), 'string');
  // A limited account cannot plant message requests through note_dm_request either.
  await h.admin();
  await h.q(`insert into t587_limited (user_id) values ($1)`, [gus]);
  await h.q(`update profiles set dms_from = 'friends' where id = $1`, [eve]);
  await h.as(gus);
  await h.fails('limited account: note_dm_request refused by standing_guard', `select note_dm_request($1)`, [eve]);
  await h.admin();
  await h.q(`insert into dm_captcha_passes (user_id, until) values ($1, now() - interval '1 day')`, [gus]);
  await h.q(`select dm_open_log_trim()`);
  h.eq('trim drops expired passes', (await h.one(`select count(*)::int n from dm_captcha_passes where user_id = $1`, [gus])).n, 0);
  // Nobody can read or write the tables directly.
  await h.as(ann);
  await h.fails('clients cannot read dm_open_log', `select * from dm_open_log`);
  await h.fails('clients cannot write passes', `insert into dm_captcha_passes (user_id, until) values ($1, now() + interval '1 day')`, [ann]);
  await h.fails('clients cannot call dm_new_targets', `select dm_new_targets($1, $1)`, [ann]);
  await h.admin();
  await h.q(`select dm_open_log_trim()`);
  h.eq('trim keeps the fresh rows', (await h.one(`select count(*)::int n from dm_open_log`)).n > 0, true);
}
