// 443: two Promoted bot spots instead of four. Runs 441 then 443 on the stage441 stand-ins: a 3rd bot queues,
// promoted_bots() shows two at most, and 443 re-runs.
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
  const MIG = mig('443_bot_promo_two_spots.sql');
  await h.ok('443 runs', () => h.db.exec(MIG));
  await h.ok('443 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('two spots', (await h.one(`select bot_promo_slots() n`)).n, 2);

  const a = await h.signup('a@test.dev', 'alice');
  const bots = [];
  for (let i = 0; i < 3; i++) bots.push(await h.signup(`bot${i}@test.dev`, `bot${i}`));
  await h.admin();
  for (const id of bots) await h.q(`insert into bots (id, owner_id, name, public, verified_at) values ($1, $2, $3, true, now())`, [id, a, 'Bot ' + id.slice(0, 4)]);
  await h.q(`insert into feature_flags (key, label, mode) values ('bot_verified', 'x', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'bot_promoted'`);

  await h.db.exec(`set role service_role`);
  const starts = [];
  for (const [i, id] of bots.entries()) starts.push((await h.one(`select book_bot_promotion($1, 'stripe', $2, null, 7) - now() > interval '6 days' q`, [id, `evt_${i}`])).q);
  await h.db.exec(`reset role`);
  h.eq('first two start now, the 3rd queues', starts, [false, false, true]);
  await h.as(a);
  h.eq('promoted_bots shows two', (await h.q(`select id from promoted_bots(6)`)).length, 2);
  const av = (await h.one(`select bot_promo_availability($1) j`, [bots[0]])).j;
  h.eq('availability slots and taken', [Number(av.slots), Number(av.taken)], [2, 2]);
}
