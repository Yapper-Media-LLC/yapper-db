// 503: saved suggestion lists forget people as soon as their privacy changes (security pass 2, N5). Runs stage 459
// first (459, 461, 463 and its people), then 503 twice, then hides / unlinks / leaves and checks the lists.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import run459, { base, extra } from './stage459.test.mjs';
export { base, extra };
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '503_match_cache_privacy.sql'), 'utf8');

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`503 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await run459(h);
  await h.admin();
  await h.ok('503 runs', () => h.db.exec(MIG));
  await h.ok('503 re-runs cleanly', () => h.db.exec(MIG));

  const id = async (name) => (await h.one(`select id from profiles where username = $1`, [name])).id;
  const me = await id('me');
  // Always a fresh build (Refresh reuses a list under 5 minutes old).
  const list = async () => { await h.q(`update match_cache set computed_at = now() - interval '7 hours' where user_id = $1 and computed_at > '-infinity'`, [me]); await h.as(me); const r = (await h.one(`select my_matches(true) r`)).r; await h.admin(); return r; };
  const stale = async (uid = me) => (await h.one(`select computed_at = '-infinity' s from match_cache where user_id = $1`, [uid])).s;
  const fresh = () => h.q(`update match_cache set computed_at = now() where user_id = $1`, [me]);
  const sees = async (target) => { await h.as(me); const r = (await h.one(`select sees_user($1) s`, [target])).s; await h.admin(); return r; };

  // Someone in my list through a shared interest, whom I only see through the list.
  await h.q(`update match_cache set computed_at = now() - interval '7 hours' where user_id = $1`, [me]);
  const res = await list();
  // Their interest can come from a media connection or Steam: work on whichever table holds it.
  let pick = null;
  for (const r of res) {
    if (!r.items_n) continue;
    const m = await h.one(`select source from media_links where user_id = $1 and is_public and not coalesce((prefs ->> 'hidden')::boolean, false) limit 1`, [r.user_id]);
    if (m) { pick = { uid: r.user_id, t: 'media_links', open: 'is_public', key: `user_id = $1 and source = '${m.source}'` }; break; }
    const st = await h.one(`select 1 x from steam_links where user_id = $1 and games_public`, [r.user_id]);
    if (st) { pick = { uid: r.user_id, t: 'steam_links', open: 'games_public', key: 'user_id = $1' }; break; }
  }
  if (!pick) throw new Error('stage 459 left nobody in my list with a public connection');
  const upd = (set) => h.q(`update ${pick.t} set ${set} where ${pick.key}`, [pick.uid]);
  // Make sure only the list explains the card access (no shared server / DM / friendship in the way).
  await h.q(`delete from server_members where user_id = $1`, [pick.uid]);
  await list();
  await fresh();
  h.eq('in my list', (await h.one(`select results @> jsonb_build_array(jsonb_build_object('user_id', $2::text)) x from match_cache where user_id = $1`, [me, pick.uid])).x, true);
  h.eq('so I can open their card', await sees(pick.uid), true);

  // A refresh or a pin edit rewrites the same columns without hiding anything: the list stays.
  await upd(`${pick.open} = true, prefs = coalesce(prefs, '{}'::jsonb) || '{"pins": [1]}'`);
  h.eq('a no-op refresh or a pin edit keeps the list', await stale(), false);

  // They hide the connection: my saved list is stale at once, and the card access through it is gone.
  await upd(`prefs = coalesce(prefs, '{}'::jsonb) || '{"hidden": true}'`);
  h.eq('hiding a connection marks lists naming them stale', await stale(), true);
  h.eq('their card is no longer open to me through the list', await sees(pick.uid), false);
  h.eq('the rebuilt list no longer names them for that interest', (await list()).some((r) => r.user_id === pick.uid && r.items_n > 0), false);

  // Unhide, back in; then private; then disconnect.
  await upd(`prefs = prefs - 'hidden'`);
  await list();
  await fresh();
  await upd(`${pick.open} = false`);
  h.eq('making it private marks lists stale', await stale(), true);
  await upd(`${pick.open} = true`);
  await list();
  await fresh();
  await h.q(`delete from ${pick.t} where ${pick.key}`, [pick.uid]);
  h.eq('disconnecting marks lists stale', await stale(), true);

  // Leaving a server: lists naming the leaver, and the leaver's own, go stale.
  const other = res.find((r) => r.user_id !== pick.uid)?.user_id;
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S499', $1) returning id`, [me])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, me, other]);
  await list();
  await fresh();
  await h.q(`insert into match_cache (user_id, computed_at, results) values ($1, now(), '[]') on conflict (user_id) do update set computed_at = now()`, [other]);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [sid, other]);
  h.eq('leaving a server marks lists naming the leaver stale', await stale(), true);
  h.eq('and the leaver\'s own list', await stale(other), true);

  // A big delete (a server removed): every fresh list, in one update.
  const many = [];
  for (let i = 0; i < 55; i++) many.push(await h.signup(`bulk${i}@test.dev`, `bulk${i}`));
  await h.admin();
  const big = (await h.one(`insert into servers (name, owner_id) values ('Big', $1) returning id`, [many[0]])).id;
  await h.q(`insert into server_members (server_id, user_id) select $1, unnest($2::uuid[]) on conflict do nothing`, [big, many]);
  await fresh();
  await h.q(`delete from server_members where server_id = $1`, [big]);
  h.eq('a big delete marks every fresh list stale', await stale(), true);
  h.eq('nothing fresh left', (await h.one(`select count(*)::int n from match_cache where computed_at > now() - interval '6 hours'`)).n, 0);

  // Flag off: the list doesn't open cards any more.
  await list();
  await fresh();
  const still = (await h.one(`select results from match_cache where user_id = $1`, [me])).results.map((r) => r.user_id);
  const target = still.find(Boolean);
  if (target) {
    await h.q(`delete from server_members where user_id = $1 and server_id <> $2`, [target, sid]);
    await fresh();
    await h.q(`update feature_flags set users = '{}', servers = '{}', mode = 'test' where key = 'interest_matches'`);
    h.eq('flag off for me: no card access through the list', await sees(target), false);
  }

  // Not callable from the app.
  await h.as(me);
  await h.fails('users can\'t mark lists', `select match_cache_forget(array[$1]::uuid[])`, [me]);
  await h.admin();
}
