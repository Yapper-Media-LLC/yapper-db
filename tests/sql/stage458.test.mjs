// 458: steam_links and media_links can't be read in bulk any more. You read your own row, and someone else's only
// when you share a server, are friends (or have a pending request), or share a DM. Hidden rows stay yours alone.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  for (const f of ['447_steam_link.sql', '450_steam_prefs.sql', '457_media_connections.sql']) await h.db.exec(mig(f));
  const MIG = mig('458_links_rls_scope.sql');
  await h.ok('458 runs', () => h.db.exec(MIG));
  await h.ok('458 re-runs cleanly', () => h.db.exec(MIG));

  const me = await h.signup('me@test.dev', 'me');
  const mate = await h.signup('mate@test.dev', 'mate'); // shares a server
  const pal = await h.signup('pal@test.dev', 'pal'); // friend
  const asker = await h.signup('asker@test.dev', 'asker'); // pending request to me
  const dm = await h.signup('dm@test.dev', 'dm'); // shares a DM
  const nobody = await h.signup('nobody@test.dev', 'nobody'); // no relation
  const all = [me, mate, pal, asker, dm, nobody];
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [mate])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, me, mate]);
  await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted'), ($3, $1, 'pending')`, [me, pal, asker]);
  const cid = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'k') returning id`)).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [cid, me, dm]);
  await h.db.exec(`set role service_role`);
  for (let i = 0; i < all.length; i++) {
    await h.q(`insert into steam_links (user_id, steam_id, persona) values ($1, $2, 'P')`, [all[i], `7656119800000000${i}`]);
    await h.q(`insert into media_links (user_id, source, account_id) values ($1, 'anilist', $2)`, [all[i], `${i + 1}`]);
  }
  await h.db.exec(`reset role`);

  await h.as(me);
  const seen = async (t) => (await h.q(`select user_id from ${t}`)).map((r) => r.user_id).sort();
  h.eq('steam: own, server mate, friend, asker, dm partner', await seen('steam_links'), [me, mate, pal, asker, dm].sort());
  h.eq('media: same five', await seen('media_links'), [me, mate, pal, asker, dm].sort());
  h.eq('a stranger’s steam row is not readable', (await h.q(`select 1 from steam_links where user_id = $1`, [nobody])).length, 0);
  h.eq('a stranger’s media row is not readable', (await h.q(`select 1 from media_links where user_id = $1`, [nobody])).length, 0);

  await h.as(nobody);
  h.eq('a throwaway with no servers sees only itself (steam)', await seen('steam_links'), [nobody]);
  h.eq('a throwaway with no servers sees only itself (media)', await seen('media_links'), [nobody]);

  await h.as(mate);
  await h.q(`update steam_links set prefs = '{"hidden":true}' where user_id = $1`, [mate]);
  await h.q(`update media_links set prefs = '{"hidden":true}' where user_id = $1`, [mate]);
  await h.as(me);
  h.eq('hidden still hides from a server mate (steam)', (await h.q(`select 1 from steam_links where user_id = $1`, [mate])).length, 0);
  h.eq('hidden still hides from a server mate (media)', (await h.q(`select 1 from media_links where user_id = $1`, [mate])).length, 0);
  await h.as(mate);
  h.eq('you still see your own hidden row', (await h.q(`select 1 from steam_links where user_id = $1`, [mate])).length, 1);

  await h.as(null);
  await h.fails('anon reads nothing', `select 1 from steam_links`);
  await h.admin();
  await h.db.exec(`set role service_role`);
  h.eq('the server still reads every row', (await h.q(`select count(*)::int n from steam_links`))[0].n, all.length);
  await h.db.exec(`reset role`);
}
