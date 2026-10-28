// 445: boosts give a place (top 20 / 10 / 5), they don't multiply. Runs 441, 443, 444 and 445 on the stage441
// stand-ins with 25 listed bots far apart in servers, so the old ×8 would have taken #1.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage441.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  for (const f of ['441_bot_promoted.sql', '443_bot_promo_two_spots.sql', '444_bot_boosts.sql']) await h.db.exec(mig(f));
  const MIG = mig('445_bot_boost_nerf.sql');
  await h.ok('445 runs', () => h.db.exec(MIG));
  await h.ok('445 re-runs cleanly', () => h.db.exec(MIG));

  const a = await h.signup('a@test.dev', 'alice');
  const bots = [];
  for (let i = 0; i < 25; i++) bots.push(await h.signup(`bot${i}@test.dev`, `bot${i}`));
  await h.admin();
  // bot i is in 260 - 10i servers: #1 has 260, #15 has 120 (×8 would be 960 and take #1 under 444).
  for (const [i, id] of bots.entries()) await h.q(`insert into bots (id, owner_id, name, public, verified_at, real_servers) values ($1, $2, $3, true, now(), $4)`, [id, a, `Bot${String(i).padStart(2, '0')}`, 260 - 10 * i]);
  await h.q(`insert into feature_flags (key, label, mode) values ('bot_verified', 'x', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  await h.q(`update feature_flags set mode = 'test', users = array[$1]::uuid[], servers = '{}' where key = 'bot_promoted'`, [a]);
  const rank = async (id) => (await h.q(`select id from public_bots(null, null, 'popular', 100, 0)`)).findIndex((r) => r.id === id) + 1;

  await h.as(a);
  const last = (await h.one(`select bot_rank_tiers($1) j`, [bots[24]])).j;
  h.eq('last bot preview: now / x2 / x4 / x8', [last.now, last.x2, last.x4, last.x8].map(Number), [25, 19, 9, 4]);
  const mid = (await h.one(`select bot_rank_tiers($1) j`, [bots[14]])).j;
  h.eq('#15 bot preview: ×2 changes nothing, ×8 gets #4', [mid.now, mid.x2, mid.x4, mid.x8].map(Number), [15, 15, 9, 4]);
  const top = (await h.one(`select bot_rank_tiers($1) j`, [bots[0]])).j;
  h.eq('#1 bot stays #1', Number(top.x8), 1);

  await h.admin();
  await h.db.exec(`set role service_role`);
  await h.q(`select book_bot_boost($1, 8, 'stripe', 'evt_8', null, 7)`, [bots[14]]);
  await h.db.exec(`reset role`);
  await h.as(a);
  h.eq('#15 bot with Mega Boost is #4, not #1', await rank(bots[14]), 4);
  h.eq('the old #1 keeps #1', await rank(bots[0]), 1);
  h.eq('label still shows', (await h.one(`select boost from public_bots(null, null, 'popular', 100, 0) where id = $1`, [bots[14]])).boost, 8);
  await h.fails('bot_order still not callable', `select * from bot_order(null, null, true)`);
}
