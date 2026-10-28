// 618: decoration sales pay the artist 70%, and selling needs a 5+ day old account or Plus. Runs 468's whole test
// first (its setup has 345 + 462 + 468 and the stand-ins), then 618 on top.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import run468 from './stage468.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await run468(h);
  await h.admin();
  const MIG = mig('618_deco_sale_rules.sql');
  await h.ok('618 runs', () => h.db.exec(MIG));
  await h.ok('618 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('artist share is 70', (await h.one(`select shard_config()->>'artist_share' s`)).s, '70');

  const u = {};
  for (const n of ['fresh', 'freshplus', 'old', 'buyer']) u[n] = await h.signup(`${n}618@test.dev`, `${n}618`);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'shards'`);
  await h.q(`update profiles set created_at = now() - interval '2 days' where id in ($1, $2)`, [u.fresh, u.freshplus]);
  await h.q(`update profiles set plus_until = now() + interval '30 days' where id = $1`, [u.freshplus]);
  await h.q(`update profiles set created_at = now() - interval '30 days' where id in ($1, $2)`, [u.old, u.buyer]);
  const deco = async (who, name) => (await h.one(`insert into community_decos (name, artist_id, path, status) values ($1, $2, $3, 'approved') returning id`, [name, who, `${who}/${name}.png`])).id;
  // The media scan trigger would want a scanned file; these rows are test fixtures.
  await h.db.exec(`set session_replication_role = replica`);
  const dFresh = await deco(u.fresh, 'fresh'), dPlus = await deco(u.freshplus, 'plus'), dOld = await deco(u.old, 'old');
  await h.db.exec(`set session_replication_role = origin`);

  await h.as(u.fresh);
  await h.fails('a 2-day-old account can\'t sell', `select set_deco_price($1, 100)`, [dFresh]);
  await h.q(`select set_deco_price($1, null)`, [dFresh]);
  h.eq('...but can keep it free', (await h.one(`select price from community_decos where id = $1`, [dFresh])).price, null);
  await h.as(u.freshplus);
  await h.q(`select set_deco_price($1, 100)`, [dPlus]);
  h.eq('Plus sells right away', (await h.one(`select price from community_decos where id = $1`, [dPlus])).price, 100);
  await h.as(u.old);
  await h.q(`select set_deco_price($1, 100)`, [dOld]);

  // A price set before the rule (or by a Plus member whose Plus ran out) can't be bought until the artist qualifies.
  await h.admin();
  await h.q(`update community_decos set price = 100 where id = $1`, [dFresh]);
  await h.q(`insert into shard_wallets (user_id, balance) values ($1, 1000) on conflict (user_id) do update set balance = 1000`, [u.buyer]);
  await h.q(`insert into shard_ledger (user_id, amount, kind, note, balance_after) values ($1, 1000, 'staff_adjust', 'test', 1000)`, [u.buyer]);
  await h.as(u.buyer);
  await h.fails('can\'t buy from an artist who can\'t sell', `select buy_community_deco($1, 100)`, [dFresh]);
  await h.q(`select buy_community_deco($1, 100)`, [dOld]);
  await h.admin();
  h.eq('the artist gets 70%', (await h.one(`select balance from shard_wallets where user_id = $1`, [u.old])).balance, 70);
  await h.as(u.buyer);
  await h.fails('no deco_seller_ok from clients', `select deco_seller_ok($1)`, [u.old]);
}
