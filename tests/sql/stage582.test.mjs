// 582: group chat caps. Starts from stage 24 (channels, group chats from 008, friends from 007, site_admins from 019)
// plus the flags tables (031/041) and stand-ins for the later bits the migration touches (is_staff, site_moderators,
// raid_alerts, bc_notice).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '582_group_chat_cap.sql'), 'utf8');

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid()) or exists (select 1 from public.site_admins where user_id = auth.uid());
$$;
create table if not exists public.raid_alerts (
  id uuid primary key default gen_random_uuid(), kind text not null check (kind in ('server', 'signup_domain', 'signup_ip')),
  server_id uuid, key text, user_ids uuid[] not null default '{}', staff boolean not null default false,
  created_at timestamptz not null default now(), until timestamptz, resolved_at timestamptz, resolved_by uuid, banned int not null default 0);
create table if not exists public.t582_notices (topic text, event text, payload jsonb);
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language sql as $$
  insert into public.t582_notices values (topic_name, event_name, payload);
$$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('582 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag gc_cap is in test mode', (await h.one(`select mode from feature_flags where key = 'gc_cap'`)).mode, 'test');

  const ann = await h.signup('ann@test.dev', 'ann');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  const dan = await h.signup('dan@test.dev', 'dan');
  const staff = await h.signup('staff@test.dev', 'staff');
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 days'`); // past the new-account slowmode (024)
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [mod]);
  // Everyone is friends with everyone (check_addable wants friends).
  const all = [ann, bob, cat, dan, staff, mod];
  for (const x of all) for (const y of all) if (x < y) await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted')`, [x, y]);

  const make = async (who, people, name = 'g') => { await h.as(who); return (await h.one(`select create_group($1, null, $2::uuid[]) id`, [name, people])).id; };
  const backdate = async (who, iv) => { await h.admin(); await h.q(`update group_add_log set created_at = now() - $2::interval where actor = $1`, [who, iv]); };
  // Spread the messages out in time: the new-account slowmode trigger wants 3 seconds between a person's messages.
  let tick = 0;
  const say = async (who, cid) => { await h.admin(); await h.q(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, 'hi', now() - interval '3 hours' + ($3::int * interval '10 seconds'))`, [cid, who, tick++]); };
  const owned = async (who) => (await h.one(`select count(*)::int n from channels c where c.kind = 'group' and c.created_by = $1 and exists (select 1 from channel_members m where m.channel_id = c.id and m.user_id = $1)`, [who])).n;
  const alerts = async () => h.q(`select kind, key, user_ids, staff from raid_alerts order by created_at`);

  // ----- creation rate: 3 per 10 minutes -----
  const g1 = await make(ann, [bob]);
  const g2 = await make(ann, [bob]);
  const g3 = await make(ann, [bob]);
  await h.as(ann);
  await h.fails('4th group chat in 10 minutes is refused', `select create_group('g', null, $1::uuid[])`, [[cat]]);
  await h.admin();
  h.eq('log has 3 create rows for ann', (await h.one(`select count(*)::int n from group_add_log where actor = $1 and via = 'create'`, [ann])).n, 3);
  // Leaving (and deleting) a chat does not reset the rate limit: the log row has no FK.
  await h.as(ann); await h.q(`select leave_group($1)`, [g3]);
  await h.admin();
  h.eq('empty group chat was deleted', (await h.one(`select count(*)::int n from channels where id = $1`, [g3])).n, 1); // bob is still in it
  await h.as(ann);
  await h.fails('still refused after leaving one', `select create_group('g', null, $1::uuid[])`, [[cat]]);

  // ----- unanswered cap: 3 silent group chats per person -----
  await backdate(ann, '11 minutes');
  await h.as(ann);
  await h.fails('bob has not answered in 3 chats: no 4th with bob', `select create_group('g', null, $1::uuid[])`, [[bob]]);
  let err = '';
  try { await h.q(`select create_group('g', null, $1::uuid[])`, [[bob]]); } catch (e) { err = e.message; }
  h.eq('friendly wording', /haven't said anything/.test(err), true);
  const g4 = await make(ann, [cat]);
  h.eq('cat is fine (first chat with her)', typeof g4, 'string');
  await say(bob, g1);
  const g5 = await make(ann, [bob]);
  h.eq('bob answered in one, so a new one with bob works', typeof g5, 'string');
  await h.as(ann);
  await h.fails('and now bob is at 3 silent ones again', `select create_group('g', null, $1::uuid[])`, [[bob]]);
  // Mixed list: one bad person refuses the whole chat.
  await h.fails('a list with a capped person is refused as a whole', `select create_group('g', null, $1::uuid[])`, [[dan, bob]]);
  await h.admin();
  h.eq('no chat was made for the refused list', (await h.one(`select count(*)::int n from group_add_log where actor = $1 and target = $2`, [ann, dan])).n, 0);

  // ----- daily cap: 10 a day, with a staff alert on the 10th -----
  // ann has 5 creates today (g1..g5). Make 5 more with dan, who answers each time, backdating past the 10 minute window.
  let last;
  for (let i = 0; i < 5; i++) {
    await backdate(ann, '11 minutes');
    last = await make(ann, [dan]);
    await say(dan, last);
  }
  await backdate(ann, '11 minutes');
  await h.as(ann);
  await h.fails('11th group chat of the day is refused', `select create_group('g', null, $1::uuid[])`, [[dan]]);
  err = '';
  try { await h.q(`select create_group('g', null, $1::uuid[])`, [[dan]]); } catch (e) { err = e.message; }
  h.eq('daily wording', /enough group chats for today/.test(err), true);
  await h.admin();
  let a = await alerts();
  h.eq('one group_spam alert for ann, for staff', a, [{ kind: 'group_spam', key: ann, user_ids: [ann], staff: true }]);
  const notes = await h.q(`select topic, event from t582_notices order by ctid`);
  h.eq('both staff members got a live notice', notes.map((n) => n.topic).sort(), [`user:${mod}`, `user:${staff}`].sort());
  h.eq('notice event is raid_alert', notes[0].event, 'raid_alert');

  // ----- owned cap: 20 group chats you made and are still in -----
  await h.admin();
  await h.q(`update group_add_log set created_at = now() - interval '2 days' where actor = $1`, [ann]);
  h.eq('ann owns 9 now (left g3)', await owned(ann), 9);
  for (let i = 0; i < 11; i++) {
    await backdate(ann, '2 days');
    last = await make(ann, [dan]);
    await say(dan, last);
  }
  h.eq('ann owns 20', await owned(ann), 20);
  await backdate(ann, '2 days');
  await h.as(ann);
  await h.fails('21st owned group chat is refused', `select create_group('g', null, $1::uuid[])`, [[dan]]);
  await h.q(`select leave_group($1)`, [last]);
  const g6 = await make(ann, [dan]);
  h.eq('after leaving one, a new one works', typeof g6, 'string');
  await h.admin();
  a = await alerts();
  h.eq('still only one alert (one a day per person)', a.length, 1);

  // ----- staff are exempt from the counts -----
  for (let i = 0; i < 12; i++) await make(staff, [dan]);
  await h.admin();
  h.eq('staff made 12 group chats in a row with a silent dan', await owned(staff), 12);
  h.eq('no alert for staff', (await alerts()).length, 1);

  // ----- add_group_members: unanswered cap and the add rate -----
  const gb = await make(bob, [cat]);
  await say(cat, gb);
  await h.as(bob);
  await h.q(`select add_group_members($1, $2::uuid[])`, [gb, [ann]]);
  await h.admin();
  h.eq('add logged as via add', (await h.one(`select via from group_add_log where actor = $1 and target = $2`, [bob, ann])).via, 'add');
  // bob puts dan in 3 silent chats, then cannot add him to a 4th.
  const gb2 = await make(bob, [cat]); const gb3 = await make(bob, [cat]);
  await backdate(bob, '11 minutes');
  const gb4 = await make(bob, [cat]);
  for (const c of [gb, gb2, gb3]) { await h.as(bob); await h.q(`select add_group_members($1, $2::uuid[])`, [c, [dan]]); }
  await h.as(bob);
  await h.fails('dan is silent in 3 of bob\'s chats: no 4th add', `select add_group_members($1, $2::uuid[])`, [gb4, [dan]]);
  await say(dan, gb2);
  await h.as(bob);
  await h.q(`select add_group_members($1, $2::uuid[])`, [gb4, [dan]]);
  h.eq('after dan answers, the add works', (await h.one(`select count(*)::int n from channel_members where channel_id = $1 and user_id = $2`, [gb4, dan])).n, 1);
  // Add rate: 20 per 10 minutes.
  await h.admin();
  await h.q(`delete from group_add_log where actor = $1 and via = 'add'`, [bob]);
  await h.q(`insert into group_add_log (actor, target, channel_id, via) select $1, $2, gen_random_uuid(), 'add' from generate_series(1, 20)`, [bob, cat]);
  await h.q(`delete from channel_members where channel_id = $1 and user_id = $2`, [gb4, dan]);
  await h.as(bob);
  await h.fails('21st add in 10 minutes is refused', `select add_group_members($1, $2::uuid[])`, [gb4, [dan]]);
  await h.admin();
  await h.q(`update group_add_log set created_at = now() - interval '11 minutes' where actor = $1 and via = 'add'`, [bob]);
  await h.as(bob);
  await h.q(`select add_group_members($1, $2::uuid[])`, [gb4, [dan]]);
  h.eq('after the window, the add works', (await h.one(`select count(*)::int n from channel_members where channel_id = $1 and user_id = $2`, [gb4, dan])).n, 1);

  // ----- leave_group_block: the creator and the adder cannot add me again -----
  await h.as(ann);
  await h.fails('leave_group_block needs to be a member', `select leave_group_block($1)`, [gb4]);
  await h.as(dan);
  await h.q(`select leave_group_block($1)`, [gb4]);
  h.eq('dan is out', (await h.one(`select count(*)::int n from channel_members where channel_id = $1 and user_id = $2`, [gb4, dan])).n, 0);
  h.eq('dan sees his own optouts (bob made it and added him)', (await h.q(`select from_user from group_add_optouts order by from_user`)).map((r) => r.from_user), [bob]);
  await h.as(bob);
  await h.fails('bob cannot add dan back', `select add_group_members($1, $2::uuid[])`, [gb4, [dan]]);
  await h.fails('bob cannot start a new chat with dan either', `select create_group('g', null, $1::uuid[])`, [[dan]]);
  err = '';
  try { await h.q(`select create_group('g', null, $1::uuid[])`, [[dan]]); } catch (e) { err = e.message; }
  h.eq('optout wording', /turned off group chat invites/.test(err), true);
  await h.as(cat);
  await h.q(`select add_group_members($1, $2::uuid[])`, [gb4, [dan]]);
  h.eq('cat can still add dan', (await h.one(`select count(*)::int n from channel_members where channel_id = $1 and user_id = $2`, [gb4, dan])).n, 1);
  await h.as(dan);
  await h.q(`select group_add_optout($1, true)`, [staff]);
  await h.as(staff);
  await h.fails('staff are not exempt from an optout', `select create_group('g', null, $1::uuid[])`, [[dan]]);
  await h.as(dan);
  await h.q(`select group_add_optout($1, false)`, [staff]);
  await h.q(`select group_add_optout($1, false)`, [bob]);
  h.eq('optout removed by hand', (await h.q(`select 1 from group_add_optouts`)).length, 0);
  await h.as(bob);
  await h.fails('cannot opt out of yourself', `select group_add_optout($1, true)`, [bob]);

  // ----- leave_groups_from: out of every chat this person made -----
  await h.admin();
  const danIn = (await h.one(`select count(*)::int n from channel_members m join channels c on c.id = m.channel_id where m.user_id = $1 and c.created_by = $2 and c.kind = 'group'`, [dan, ann])).n;
  h.eq('dan is in many of ann\'s chats', danIn > 10, true);
  await h.as(dan);
  const n = (await h.one(`select leave_groups_from($1, true) n`, [ann])).n;
  h.eq('left them all', n, danIn);
  await h.admin();
  h.eq('nobody else was removed', (await h.one(`select count(*)::int n from channel_members m join channels c on c.id = m.channel_id where c.created_by = $1 and c.kind = 'group' and m.user_id = $1`, [ann])).n, 20);
  h.eq('dan is in none of ann\'s chats now', (await h.one(`select count(*)::int n from channel_members m join channels c on c.id = m.channel_id where m.user_id = $1 and c.created_by = $2`, [dan, ann])).n, 0);
  await h.admin();
  await h.q(`insert into channel_members (channel_id, user_id) select c.id, $1 from channels c where c.created_by = $2 and c.kind = 'group' limit 1`, [dan, ann]);
  await h.q(`insert into group_add_log (actor, target, channel_id, via) select $2, $1, gen_random_uuid(), 'add' from generate_series(1, 250)`, [dan, ann]);
  await h.as(dan);
  h.eq('a call never does more than 200', (await h.one(`select leave_groups_from($1, false) n`, [ann])).n <= 200, true);
  h.eq('and blocked ann', (await h.q(`select from_user from group_add_optouts where user_id = $1`, [dan])).map((r) => r.from_user), [ann]);
  await h.admin();
  h.eq('ann is still in her chats (not deleted)', await owned(ann), 20);
  await h.fails('cannot leave from yourself', `select leave_groups_from($1, false)`, [dan]);

  // ----- RLS -----
  await h.as(cat);
  await h.fails('group_add_log is not readable', `select * from group_add_log`);
  h.eq('others\' optouts are hidden', (await h.q(`select * from group_add_optouts`)).length, 0);
  await h.fails('optouts cannot be inserted directly', `insert into group_add_optouts (user_id, from_user) values ($1, $2)`, [cat, ann]);
  await h.fails('group_spam_alert is not callable', `select group_spam_alert($1)`, [cat]);
  await h.fails('check_group_adds is not callable', `select check_group_adds($1, $2::uuid[], false)`, [cat, [ann]]);
}
