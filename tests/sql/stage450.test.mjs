// 450: Steam prefs. You edit only your own prefs (no other column), hidden rows are yours alone, prefs keep their
// shape, and the cache can hold 12 games and 60 achievements.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  await h.db.exec(mig('447_steam_link.sql'));
  const MIG = mig('450_steam_prefs.sql');
  await h.ok('450 runs', () => h.db.exec(MIG));
  await h.ok('450 re-runs cleanly', () => h.db.exec(MIG));

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  await h.admin();
  await h.db.exec(`set role service_role`);
  await h.q(`insert into steam_links (user_id, steam_id, persona) values ($1, '76561198000000001', 'Alice'), ($2, '76561198000000002', 'Bob')`, [a, b]);
  await h.ok('12 games fit', () => h.q(`update steam_links set games = (select jsonb_agg(jsonb_build_object('app', i)) from generate_series(1, 12) i) where user_id = $1`, [a]));
  await h.ok('60 achievements fit', () => h.q(`update steam_links set achievements = (select jsonb_agg(i) from generate_series(1, 60) i) where user_id = $1`, [a]));
  await h.fails('61 achievements refused', `update steam_links set achievements = (select jsonb_agg(i) from generate_series(1, 61) i) where user_id = $1`, [a]);
  await h.db.exec(`reset role`);

  await h.as(a);
  await h.q(`update steam_links set prefs = '{"style":"steam","show_count":false,"games":[440],"achs":["440:WIN"]}' where user_id = $1`, [a]);
  h.eq('you can set your prefs', (await h.one(`select prefs->>'style' s from steam_links where user_id = $1`, [a])).s, 'steam');
  await h.fails('no other column', `update steam_links set persona = 'x' where user_id = $1`, [a]);
  await h.fails('no steam_id swap', `update steam_links set steam_id = '76561198000000009' where user_id = $1`, [a]);
  await h.fails('bad style refused', `update steam_links set prefs = '{"style":"neon"}' where user_id = $1`, [a]);
  await h.fails('hidden must be boolean', `update steam_links set prefs = '{"hidden":"yes"}' where user_id = $1`, [a]);
  await h.fails('at most 3 pinned games', `update steam_links set prefs = '{"games":[1,2,3,4]}' where user_id = $1`, [a]);
  await h.fails('at most 8 pinned achievements', `update steam_links set prefs = '{"achs":["1:a","1:b","1:c","1:d","1:e","1:f","1:g","1:h","1:i"]}' where user_id = $1`, [a]);
  await h.fails('prefs must be an object', `update steam_links set prefs = '[]' where user_id = $1`, [a]);
  await h.q(`update steam_links set prefs = '{"style":"plain"}' where user_id = $1`, [b]);
  await h.admin();
  h.eq('someone else\u2019s prefs untouched', (await h.one(`select prefs from steam_links where user_id = $1`, [b])).prefs, {});

  await h.as(a);
  await h.q(`update steam_links set prefs = '{"hidden":true}' where user_id = $1`, [a]);
  h.eq('you still see your hidden row', (await h.q(`select 1 from steam_links where user_id = $1`, [a])).length, 1);
  await h.as(b);
  h.eq('others can\u2019t read a hidden row', (await h.q(`select 1 from steam_links where user_id = $1`, [a])).length, 0);
  h.eq('others still read visible rows', (await h.q(`select 1 from steam_links where user_id = $1`, [b])).length, 1);
  await h.as(a);
  await h.q(`update steam_links set prefs = '{"hidden":false}' where user_id = $1`, [a]);
  await h.as(b);
  h.eq('shown again', (await h.q(`select 1 from steam_links where user_id = $1`, [a])).length, 1);
  await h.admin();
}
