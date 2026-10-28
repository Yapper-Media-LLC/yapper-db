// 415: community decorations most worn first. Builds on 345 with its stand-ins.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage345.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const MORE = `
alter table public.profiles add column if not exists avatar_deco text;
alter table public.community_decos add column if not exists event text;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('345_community_decos.sql'));
  await h.db.exec(MORE);
  const MIG = mig('415_deco_popular.sql');
  await h.db.exec(MIG);
  await h.ok('415 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'deco_popular'`)).mode, 'test');

  const art = await h.signup('art@test.dev', 'artist');
  const fans = [];
  for (let i = 0; i < 3; i++) fans.push(await h.signup(`fan${i}@test.dev`, `fan${i}`));
  await h.admin();
  const add = async (name, status, ago) => {
    await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [`${art}/${name}.png`]);
    return (await h.one(
      `insert into community_decos (kind, name, artist_id, path, status, created_at) values ('deco', $1, $2, $3, $4, now() - $5::interval) returning id`,
      [name, art, `${art}/${name}.png`, status, ago])).id;
  };
  const old = await add('old', 'approved', '3 days');
  const mid = await add('mid', 'approved', '2 days');
  const fresh = await add('fresh', 'approved', '1 day');
  const waiting = await add('waiting', 'pending', '1 hour');
  const wear = (who, name) => h.q(`update profiles set avatar_deco = $2 where id = $1`, [who, `c:${art}/${name}.png`]);
  await wear(fans[0], 'old'); await wear(fans[1], 'old'); await wear(fans[2], 'mid');

  await h.as(fans[0]);
  const rows = await h.q(`select id, wearers from community_decos_popular()`);
  h.eq('most worn first, then newest among equals; waiting ones left out', rows.map((r) => [r.id, r.wearers]), [[old, 2], [mid, 1], [fresh, 0]]);
  h.eq('pages', (await h.q(`select id from community_decos_popular(1, 1)`)).map((r) => r.id), [mid]);
  h.eq('silly limits are clamped', (await h.q(`select id from community_decos_popular(-5, 9999)`)).length, 3);
  h.eq('waiting one never shows', rows.some((r) => r.id === waiting), false);
}
