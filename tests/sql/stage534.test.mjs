// 534: 2x Shards for 48 hours (100K users). Runs 468's whole test first (same base and stand-ins), then 534 on top.
// The window is real time, so the checks expect 2x inside it and 1x after it.
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
  const MIG = mig('534_shards_100k.sql');
  await h.ok('534 runs', () => h.db.exec(MIG));
  await h.ok('534 re-runs cleanly', () => h.db.exec(MIG));

  const live = new Date() >= new Date('2026-10-26T10:00:00Z') && new Date() < new Date('2026-10-28T11:00:00Z');
  const mult = live ? 2 : 1;
  const ev = (await h.one(`select shard_event() e`)).e;
  h.eq('event only inside the window', ev ? ev.mult : null, live ? 2 : null);
  if (live) h.eq('event says what it is', [ev.label, ev.ends_at], ['100K users', '2026-10-28T11:00:00Z']);

  const plain = await h.signup('plain534@test.dev', 'plain534');
  const plus = await h.signup('plus534@test.dev', 'plus534');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days', plus_until = case when id = $2 then now() + interval '30 days' end where id in ($1, $2)`, [plain, plus]);
  await h.q(`update feature_flags set mode = 'everyone' where key in ('shards', 'shard_quests')`);
  h.eq('everyone gets the event boost', Number((await h.one(`select shard_boost($1) b`, [plain])).b), mult);
  h.eq('Plus stacks on top', Number((await h.one(`select shard_boost($1) b`, [plus])).b), 1.5 * mult);
  // A purchase or sale isn't boosted: shard_post pays what it's given.
  await h.q(`select shard_post($1, 7, 'staff_adjust', 'x', 'staff')`, [plain]);
  h.eq('shard_post is not boosted', (await h.one(`select balance from shard_wallets where user_id = $1`, [plain])).balance, 7);
  await h.q(`select shard_earn($1, 5, 'quest', 'y')`, [plain]);
  h.eq('shard_earn is', (await h.one(`select balance from shard_wallets where user_id = $1`, [plain])).balance, 7 + 5 * mult);

  await h.as(plain);
  const mine = (await h.one(`select my_shards() r`)).r;
  h.eq('my_shards shows the boost and the event', [Number(mine.boost), mine.event?.mult ?? null], [mult, live ? 2 : null]);
  await h.fails('still no shard_boost from clients', `select shard_boost($1)`, [plain]);
  await h.admin();
  h.eq('every balance matches its ledger', (await h.one(`select count(*)::int n from shard_wallets w where balance <> coalesce((select sum(amount) from shard_ledger l where l.user_id = w.user_id), 0)`)).n, 0);
}
