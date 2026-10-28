// 447: Steam on profiles. Only the server writes links; everyone signed in reads them; you can delete only your own;
// one Steam account per Yapin' account; malformed ids and URLs are refused; the flag row lands in test.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  const MIG = mig('447_steam_link.sql');
  await h.ok('447 runs', () => h.db.exec(MIG));
  await h.ok('447 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag steam_link in test', (await h.one(`select mode from feature_flags where key = 'steam_link'`)).mode, 'test');

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  const A = '76561198000000001';
  const B = '76561198000000002';

  // Users can't write links themselves (the server checks Steam's answer first).
  await h.as(a);
  await h.fails('no insert as a user', `insert into steam_links (user_id, steam_id) values ($1, $2)`, [a, A]);
  await h.admin();

  await h.db.exec(`set role service_role`);
  await h.q(`insert into steam_links (user_id, steam_id, persona) values ($1, $2, 'Alice')`, [a, A]);
  await h.q(`insert into steam_links (user_id, steam_id, persona) values ($1, $2, 'Bob')`, [b, B]);
  await h.fails('one Steam account per Yapin account', `update steam_links set steam_id = $1 where user_id = $2`, [A, b]);
  await h.fails('bad SteamID refused', `update steam_links set steam_id = '123' where user_id = $1`, [a]);
  await h.fails('non-https avatar refused', `update steam_links set avatar_url = 'http://x/y.jpg' where user_id = $1`, [a]);
  await h.fails('profile link must be steamcommunity', `update steam_links set profile_url = 'https://evil.example/' where user_id = $1`, [a]);
  await h.fails('at most 12 achievements', `update steam_links set achievements = (select jsonb_agg(i) from generate_series(1, 13) i) where user_id = $1`, [a]);
  await h.q(`update steam_links set games = '[{"app":440,"name":"TF2","hours":12.5,"icon":null}]', refreshed_at = now() where user_id = $1`, [a]);
  await h.db.exec(`reset role`);

  await h.as(b);
  h.eq('others can read a link', (await h.one(`select persona from steam_links where user_id = $1`, [a])).persona, 'Alice');
  await h.fails('no update as a user', `update steam_links set persona = 'x' where user_id = $1`, [b]);
  await h.q(`delete from steam_links where user_id = $1`, [a]);
  await h.admin();
  h.eq('deleting someone else\u2019s link does nothing', (await h.one(`select count(*)::int n from steam_links where user_id = $1`, [a])).n, 1);

  await h.as(b);
  await h.q(`delete from steam_links where user_id = $1`, [b]);
  await h.admin();
  h.eq('you can disconnect your own', (await h.one(`select count(*)::int n from steam_links where user_id = $1`, [b])).n, 0);

  // Refresh turns: server only, once per gap, and a disconnect doesn't reset it.
  await h.as(a);
  await h.fails('users cannot claim refresh turns', `select steam_claim_refresh($1, 60)`, [a]);
  await h.fails('users cannot read the refresh log', `select * from steam_refresh_log`);
  await h.admin();
  await h.db.exec(`set role service_role`);
  h.eq('first claim', (await h.one(`select steam_claim_refresh($1, 3600) ok`, [a])).ok, true);
  h.eq('second claim within the gap refused', (await h.one(`select steam_claim_refresh($1, 3600) ok`, [a])).ok, false);
  await h.q(`update steam_refresh_log set at = now() - interval '2 hours' where user_id = $1`, [a]);
  h.eq('claim again after the gap', (await h.one(`select steam_claim_refresh($1, 3600) ok`, [a])).ok, true);
  await h.db.exec(`reset role`);

  await h.q(`set role anon`);
  await h.fails('anon cannot read', `select * from steam_links`);
  await h.db.exec(`reset role`);
}
