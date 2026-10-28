// 444: bot boosts. Runs 441, 443 and 444 on the stage441 stand-ins with 25 listed bots, then checks the tier
// floors (×2 top 20, ×4 top 10, ×8 top 3), who can book and see boosts, the flag gate and the ban rule.
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
  await h.db.exec(mig('441_bot_promoted.sql'));
  await h.db.exec(mig('443_bot_promo_two_spots.sql'));
  const MIG = mig('444_bot_boosts.sql');
  await h.ok('444 runs', () => h.db.exec(MIG));
  await h.ok('444 re-runs cleanly', () => h.db.exec(MIG));

  const a = await h.signup('a@test.dev', 'alice'); // owns every bot, in the test group
  const b = await h.signup('b@test.dev', 'bob'); // outside the test group
  const m = await h.signup('m@test.dev', 'mod');
  const z = await h.signup('z@test.dev', 'admin');
  const bots = [];
  for (let i = 0; i < 25; i++) bots.push(await h.signup(`bot${i}@test.dev`, `bot${i}`));
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [m]);
  await h.q(`insert into site_admins values ($1)`, [z]);
  // bot i is in 1000 - 40i servers: bot0 (1000) is #1, bot24 (40) is last, far enough apart that tier floors matter.
  for (const [i, id] of bots.entries()) await h.q(`insert into bots (id, owner_id, name, public, verified_at, real_servers) values ($1, $2, $3, true, now(), $4)`, [id, a, `Bot${String(i).padStart(2, '0')}`, 1000 - 40 * i]);
  await h.q(`insert into feature_flags (key, label, mode) values ('bot_verified', 'x', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  await h.q(`update feature_flags set mode = 'test', users = array[$1, $2]::uuid[], servers = '{}' where key = 'bot_promoted'`, [a, z]);
  const rank = async (id) => (await h.q(`select id from public_bots(null, null, 'popular', 100, 0)`)).findIndex((r) => r.id === id) + 1;

  await h.as(a);
  h.eq('plain order: last bot is #25', await rank(bots[24]), 25);
  const tiers = (await h.one(`select bot_rank_tiers($1) j`, [bots[24]])).j;
  h.eq('tier preview: now / x2 / x4 / x8', [tiers.now, tiers.x2, tiers.x4, tiers.x8].map(Number), [25, 19, 9, 2]);
  await h.as(b);
  await h.fails('others cannot read rank tiers', `select bot_rank_tiers($1)`, [bots[24]]);
  for (const who of [a, b, m, z]) {
    await h.as(who);
    await h.fails('only service_role books boosts', `select book_bot_boost($1, 8, 'stripe', 'evt_x', null, 7)`, [bots[24]]);
    await h.fails('bot_order not callable', `select * from bot_order(null, null, true)`);
  }

  await h.admin();
  await h.db.exec(`set role service_role`);
  await h.fails('unknown tier refused', `select book_bot_boost($1, 3, 'stripe', 'evt_3', null, 7)`, [bots[24]]);
  await h.q(`select book_bot_boost($1, 8, 'stripe', 'evt_8', null, 7)`, [bots[24]]);
  await h.q(`select book_bot_boost($1, 2, 'stripe', 'evt_2', null, 7)`, [bots[23]]);
  const ext = await h.one(`select book_bot_boost($1, 8, 'stripe', 'evt_8b', null, 7) - now() > interval '6 days' q`, [bots[24]]);
  h.eq('same tier again adds days', ext.q, true);
  const under = await h.one(`select book_bot_boost($1, 4, 'stripe', 'evt_4u', null, 7) - now() > interval '13 days' q`, [bots[24]]);
  h.eq('cheaper tier waits behind the bigger one', under.q, true);
  await h.db.exec(`reset role`);

  await h.as(a);
  h.eq('×8 bot lands in the top 3', (await rank(bots[24])) <= 3, true);
  h.eq('×2 bot lands in the top 20', (await rank(bots[23])) <= 20, true);
  h.eq('boost column for the label', (await h.one(`select boost from public_bots(null, null, 'popular', 100, 0) where id = $1`, [bots[24]])).boost, 8);
  h.eq('boosts don\'t take a Promoted spot', (await h.one(`select (bot_promo_availability($1) ->> 'taken')::int n`, [bots[0]])).n, 0);
  h.eq('no boost in the Promoted row', (await h.q(`select id from promoted_bots(2)`)).length, 0);
  const boostRow = (await h.one(`select id from bot_promotions where bot_id = $1 limit 1`, [bots[24]])).id;
  await h.q(`select bot_promo_event(array[$1]::uuid[], 'view')`, [boostRow]);
  await h.admin();
  await h.db.exec(`set role service_role`);
  await h.q(`select book_bot_promotion($1, 'stripe', 'evt_p', null, 7)`, [bots[1]]);
  await h.db.exec(`reset role`);
  const promoRow = (await h.one(`select id from bot_promotions where bot_id = $1 and kind = 'promote'`, [bots[1]])).id;
  await h.as(a);
  await h.q(`select bot_promo_event(array[$1]::uuid[], 'view')`, [promoRow]);
  await h.admin();
  h.eq('views count on spots, not boosts', (await h.q(`select views from bot_promotions where id in ($1, $2) order by kind`, [boostRow, promoRow])).map((r) => r.views), [0, 1]);
  await h.as(a);
  h.eq('newest sort ignores boosts', (await h.q(`select boost from public_bots(null, null, 'new', 100, 0)`)).length, 25);
  await h.as(b);
  h.eq('flag off: plain order', await rank(bots[24]), 25);
  h.eq('flag off: no label', (await h.one(`select boost from public_bots(null, null, 'popular', 100, 0) where id = $1`, [bots[24]])).boost, 0);
  await h.as(null);
  h.eq('anon (flag off): plain order', (await h.q(`select id from public_bots(null, null, 'popular', 100, 0)`)).at(-1).id, bots[24]);

  await h.admin();
  await h.q(`insert into site_bans (user_id) values ($1)`, [bots[24]]);
  await h.as(a);
  h.eq('banned bot loses its boost', (await h.one(`select boost from public_bots(null, null, 'popular', 100, 0) where id = $1`, [bots[24]])).boost, 0);
  await h.admin();
  await h.q(`delete from site_bans`);

  await h.as(a);
  h.eq('owner sees kind and tier', (await h.q(`select kind, mult from bot_promotions where bot_id = $1 order by starts_at`, [bots[24]])).map((r) => `${r.kind}${r.mult}`), ['boost8', 'boost8', 'boost4']);
  await h.as(m);
  h.eq('staff list shows boosts', (await h.q(`select kind, mult from staff_bot_promotions()`)).length, 5);
  await h.fails('mod cannot boost free', `select admin_boost_bot($1, 7, 4)`, [bots[5]]);
  const pid = (await h.one(`select id from staff_bot_promotions() where bot_id = $1`, [bots[23]])).id;
  await h.ok('mod ends a boost', () => h.q(`select staff_end_bot_promotion($1, 'chargeback')`, [pid]));
  await h.as(z);
  await h.ok('admin boosts free', () => h.q(`select admin_boost_bot($1, 3, 4)`, [bots[20]]));
  h.eq('×4 free boost lands in the top 10', (await rank(bots[20])) <= 10, true);
  await h.admin();
  h.eq('free boost logged', (await h.one(`select count(*)::int n from mod_log where action = 'bot_boost_free'`)).n, 1);
}
