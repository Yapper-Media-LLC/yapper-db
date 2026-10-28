// 437: channel_members read policy as a set check. Who sees which rows must not change: for every person, the rows
// the new policy shows are exactly the rows whose channel can_access_channel() lets them open.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '437_channel_members_read_set.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  // Bare DM and group rows, like 420's test (the real ones need a dm_key and members made by start_dm).
  await h.db.exec(`alter table public.channels drop constraint if exists channels_dm_key_check; alter table public.channels drop constraint if exists channels_kind_check;`);
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  const dan = await h.signup('dan@test.dev', 'dan');
  await h.admin();
  // A DM amy+bob, a group bob+cat, a server (amy, bob) with a public channel and a private one that lists only bob.
  const dm = (await h.one(`insert into channels (kind) values ('dm') returning id`)).id;
  const grp = (await h.one(`insert into channels (kind) values ('group') returning id`)).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $3), ($1, $4), ($2, $4), ($2, $5)`, [dm, grp, amy, bob, cat]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, amy, bob]);
  const pub = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [sid])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2)`, [pub, bob]);
  // A private channel only amy is listed in (bob is in the server but has no way in), and cat still listed in the
  // public channel of a server she isn't in (left it).
  const priv = (await h.one(`insert into channels (server_id, name, kind, private) values ($1, 'staff', 'text', true) returning id`, [sid])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($3, $4)`, [priv, amy, pub, cat]);

  // What each person saw under the old policy (can_access_channel per row).
  const seen = async (who) => {
    await h.as(who);
    return (await h.q(`select channel_id || ':' || user_id k from channel_members order by 1`)).map((r) => r.k);
  };
  const before = {};
  for (const u of [amy, bob, cat, dan]) before[u] = await seen(u);

  await h.admin();
  await h.ok('437 applies', () => h.db.exec(MIG));
  await h.ok('437 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('one read policy', (await h.one(`select count(*)::int n from pg_policies where tablename = 'channel_members' and cmd = 'SELECT'`)).n, 1);
  h.eq('it starts with the set check', (await h.one(
    `select qual ilike '%my_open_channel_ids%' ok from pg_policies where tablename = 'channel_members' and cmd = 'SELECT'`)).ok, true);

  for (const [u, name] of [[amy, 'amy'], [bob, 'bob'], [cat, 'cat'], [dan, 'dan']]) h.eq(`${name} sees the same rows as before`, await seen(u), before[u]);
  await h.as(amy);
  h.eq('amy does not see the group', (await h.one(`select count(*)::int n from channel_members where channel_id = $1`, [grp])).n, 0);
  await h.as(bob);
  h.eq('bob does not see the private channel', (await h.one(`select count(*)::int n from channel_members where channel_id = $1`, [priv])).n, 0);
  await h.as(cat);
  h.eq('cat still sees the channel she is listed in', (await h.one(`select count(*)::int n from channel_members where channel_id = $1`, [pub])).n, 2);
  await h.as(dan);
  h.eq('dan (in nothing) sees nothing', (await h.one(`select count(*)::int n from channel_members`)).n, 0);

  // Site banned: none of his DM or group rows (the live can_access_channel hides the server rows too; the base-24
  // copy used here has no ban check, so only the set branch is checked).
  await h.admin();
  await h.q(`insert into site_bans (user_id) values ($1)`, [bob]);
  await h.as(bob);
  h.eq('a site banned member sees none of his DM or group rows', (await h.one(`select count(*)::int n from channel_members where channel_id in ($1, $2)`, [dm, grp])).n, 0);
  await h.as(null);
  await h.fails('anon cannot call my_open_channel_ids', `select public.my_open_channel_ids()`);
}
