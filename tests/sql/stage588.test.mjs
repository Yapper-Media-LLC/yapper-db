// 588: friend request origin and mass remove. Starts from stage 24 (friends from 007, servers from 010) plus the flags
// tables (031/041) and friend notes (140), with stand-ins for the filters send_friend_request calls.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '140_temp_avatar_friend_notes.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '588_friend_origin_mass_remove.sql'), 'utf8');

const STANDINS = `
create or replace function public.has_slur(t text) returns boolean language sql immutable as $$ select false; $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select false; $$;
create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable as $$ select false; $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('588 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flags in test mode', (await h.one(`select count(*)::int n from feature_flags where key in ('friend_origin', 'mass_remove') and mode = 'test'`)).n, 2);
  h.eq('only one send_friend_request left', (await h.one(`select count(*)::int n from pg_proc where proname = 'send_friend_request'`)).n, 1);

  const ann = await h.signup('ann@test.dev', 'ann');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  const dan = await h.signup('dan@test.dev', 'dan');
  const eve = await h.signup('eve@test.dev', 'eve');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 days'`);
  await h.q(`update feature_flags set users = array[$1::uuid] where key in ('friend_origin', 'mass_remove')`, [ann]);
  // Servers: s1 owned by bob (ann and bob in it), s2 owned by ann, s3 owned by cat (ann in it), s4 owned by dan (ann not in it).
  const mk = async (owner, name) => { await h.as(owner); return (await h.one(`select create_server($1, null) id`, [name])).id; };
  const s1 = await mk(bob, 'one'); const s2 = await mk(ann, 'two'); const s3 = await mk(cat, 'three'); const s4 = await mk(dan, 'four');
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($3, $2)`, [s1, ann, s3]);

  // ----- 7: origin -----
  await h.as(ann);
  h.eq('old two-argument call still works', (await h.one(`select send_friend_request('bob', null) r`)).r, 'sent');
  await h.admin();
  h.eq('no server given: via_server empty', (await h.one(`select via_server v from friendships where requester = $1 and addressee = $2`, [ann, bob])).v, null);
  await h.as(ann);
  h.eq('request from a shared server', (await h.one(`select send_friend_request('cat', null, $1) r`, [s3])).r, 'sent');
  h.eq('request naming a server the other is not in', (await h.one(`select send_friend_request('dan', null, $1) r`, [s1])).r, 'sent');
  await h.admin();
  h.eq('shared server sticks', (await h.one(`select via_server v from friendships where requester = $1 and addressee = $2`, [ann, cat])).v, s3);
  h.eq('unshared server does not', (await h.one(`select via_server v from friendships where requester = $1 and addressee = $2`, [ann, dan])).v, null);
  // cat accepts; bob and cat are friends with each other too, so ann and cat share bob once bob accepts.
  await h.as(cat); await h.q(`select respond_friend_request($1, true)`, [ann]);
  await h.as(bob); await h.q(`select respond_friend_request($1, true)`, [ann]);
  await h.admin();
  await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted')`, [bob, cat]);
  await h.as(ann);
  const info = await h.q(`select other, via_server, mutual_friends from friends_info() order by mutual_friends desc`);
  h.eq('friends_info lists all three', info.length, 3);
  const byId = Object.fromEntries(info.map((r) => [r.other, r]));
  h.eq('cat: came from server three, one mutual friend (bob)', [byId[cat].via_server, byId[cat].mutual_friends], [s3, 1]);
  h.eq('bob: no origin, one mutual friend (cat)', [byId[bob].via_server, byId[bob].mutual_friends], [null, 1]);
  h.eq('dan: pending, no mutuals', [byId[dan].via_server, byId[dan].mutual_friends], [null, 0]);
  await h.as(eve);
  h.eq('flag off: friends_info is empty', (await h.q(`select * from friends_info()`)).length, 0);

  // ----- 5: mass remove -----
  await h.as(ann);
  h.eq('remove_friends drops both accepted and pending', (await h.one(`select remove_friends($1::uuid[]) n`, [[bob, dan, eve]])).n, 2);
  await h.admin();
  h.eq('cat is still a friend', (await h.one(`select count(*)::int n from friendships where $1 in (requester, addressee)`, [ann])).n, 1);
  await h.as(eve);
  await h.fails('flag off: remove_friends refused', `select remove_friends($1::uuid[])`, [[ann]]);
  await h.as(ann);
  h.eq('leave_servers skips the one I own and the one I am not in', (await h.one(`select leave_servers($1::uuid[]) n`, [[s1, s2, s3, s4]])).n, 2);
  await h.admin();
  h.eq('ann is only in her own server now', (await h.q(`select server_id from server_members where user_id = $1`, [ann])).map((r) => r.server_id), [s2]);
  await h.as(ann);
  await h.fails('over the cap', `select leave_servers((select array_agg(gen_random_uuid()) from generate_series(1, 101)))`);
}
