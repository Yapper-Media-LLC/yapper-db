// 583: DM privacy defaults. Starts from stage 24 (group chats from 008, friends from 007) plus the flags tables (031/041).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '583_dm_privacy.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(MIG);
  await h.ok('583 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag dm_card is in test mode', (await h.one(`select mode from feature_flags where key = 'dm_card'`)).mode, 'test');
  h.eq('flag dm_privacy is in test mode', (await h.one(`select mode from feature_flags where key = 'dm_privacy'`)).mode, 'test');
  h.eq('group_adds defaults to friends (nothing changes before publish)', (await h.one(`select column_default d from information_schema.columns where table_name = 'profiles' and column_name = 'group_adds'`)).d, `'friends'::text`);

  const ann = await h.signup('ann@test.dev', 'ann');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 days'`);
  for (const [x, y] of [[ann, bob], [ann, cat], [bob, cat]]) await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted')`, [x, y]);

  // bob turns group adds off (his own row only).
  await h.as(bob);
  await h.q(`update profiles set group_adds = 'nobody' where id = $1`, [bob]);
  h.eq('bob saved group_adds = nobody', (await h.one(`select group_adds g from profiles where id = $1`, [bob])).g, 'nobody');
  await h.q(`update profiles set group_adds = 'nobody' where id = $1`, [ann]);
  await h.admin();
  h.eq('bob cannot change ann\'s setting', (await h.one(`select group_adds g from profiles where id = $1`, [ann])).g, 'friends');
  await h.as(bob);
  await h.fails('bad value is refused', `update profiles set group_adds = 'anyone' where id = $1`, [bob]);

  // Flag off for ann: adding bob still works (today's behaviour).
  await h.as(ann);
  const g1 = (await h.one(`select create_group('g', null, $1::uuid[]) id`, [[bob]])).id;
  h.eq('flag off: friend can still add bob', typeof g1, 'string');

  // Flag on for ann (test mode, users list): bob's choice is enforced, with his name in the message.
  await h.admin();
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'dm_privacy'`, [ann]);
  await h.as(ann);
  await h.fails('flag on: ann cannot put bob in a new group chat', `select create_group('g', null, $1::uuid[])`, [[bob]]);
  let err = '';
  try { await h.q(`select create_group('g', null, $1::uuid[])`, [[bob]]); } catch (e) { err = e.message; }
  h.eq('friendly wording with the name', /bob doesn't let people add them to group chats/.test(err), true);
  const g2 = (await h.one(`select create_group('g', null, $1::uuid[]) id`, [[cat]])).id;
  h.eq('cat (friends) can still be added', typeof g2, 'string');
  await h.fails('flag on: ann cannot add bob to an existing group chat either', `select add_group_members($1, $2::uuid[])`, [g2, [bob]]);
  // cat is not on the flag: she can still add bob (until publish).
  await h.as(cat);
  const g3 = (await h.one(`select create_group('g', null, $1::uuid[]) id`, [[bob]])).id;
  h.eq('flag off for cat: she can still add bob', typeof g3, 'string');
  // Published: everyone enforces it.
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'dm_privacy'`);
  await h.as(cat);
  await h.fails('published: cat cannot add bob', `select create_group('g', null, $1::uuid[])`, [[bob]]);
  // bob switches it back on.
  await h.as(bob);
  await h.q(`update profiles set group_adds = 'friends' where id = $1`, [bob]);
  await h.as(cat);
  const g4 = (await h.one(`select create_group('g', null, $1::uuid[]) id`, [[bob]])).id;
  h.eq('bob allows friends again: cat can add him', typeof g4, 'string');
}
