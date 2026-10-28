// 399: Plus members get 4000 character messages (flag plus_4000); free stays at 2000; edits count; custom emojis
// count as :name:. Starts from stage 24 (+ flags 031/041) with a plus_until stand-in.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  await h.db.exec(`alter table public.profiles add column if not exists plus_until timestamptz;`);
  const MIG = mig('399_plus_4000.sql');
  await h.ok('399 applies', () => h.db.exec(MIG));
  await h.ok('399 re-runs cleanly', () => h.db.exec(MIG));

  const plus = await h.signup('plus@test.dev', 'plusser');
  const free = await h.signup('free@test.dev', 'freebie');
  await h.admin();
  await h.q(`update profiles set plus_until = now() + interval '30 days' where id = $1`, [plus]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [plus])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, plus, free]);
  const cid = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [sid])).id;
  const long = 'x'.repeat(3000);
  const tooLong = 'x'.repeat(4001);

  // Flag off: everyone at 2000.
  await h.as(plus);
  await h.fails('flag off: plus member still 2000', `insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, plus, long]);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'plus_4000'`);

  await h.as(plus);
  const mid = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, $3) returning id`, [cid, plus, long])).id;
  h.eq('plus: 3000 goes through', typeof mid, 'string');
  await h.fails('plus: 4001 refused', `insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, plus, tooLong]);
  await h.ok('plus: edit up to 4000', () => h.q(`update messages set content = $1 where id = $2`, ['y'.repeat(4000), mid]));
  await h.fails('plus: edit past 4000 refused', `update messages set content = $1 where id = $2`, [tooLong, mid]);

  await h.as(free);
  await h.fails('free: 2001 refused', `insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, free, 'x'.repeat(2001)]);
  await h.ok('free: 2000 fine', () => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, free, 'x'.repeat(2000)]));

  // Custom emojis: counted as :name: for the limit, but the stored text has a hard 4000 cap, with a readable error.
  const emo = '<:party:11111111-1111-1111-1111-111111111111>';
  await new Promise((r) => setTimeout(r, 3200)); // new-account slowmode: one message every 3 s
  await h.as(plus);
  await h.ok('plus: 3990 visible plus one custom emoji goes through (stored under 4000)', () => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, plus, 'x'.repeat(3900) + emo]));
  let msg = '';
  await new Promise((r) => setTimeout(r, 3200));
  try { await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, plus, 'x'.repeat(3990) + emo + emo]); } catch (e) { msg = e.message; }
  h.eq('plus: stored text over 4000 gets the emoji message', /custom emojis/.test(msg), true);

  // Plus ran out: back to 2000 for new messages, but a long one already sent can still be edited without growing.
  await h.admin();
  await h.q(`update profiles set plus_until = now() - interval '1 day' where id = $1`, [plus]);
  await h.as(plus);
  await h.fails('expired plus: 2001 refused', `insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, plus, 'x'.repeat(2001)]);
  await h.ok('expired plus: same-length edit of an old 4000 one still works', () => h.q(`update messages set content = $1 where id = $2`, ['z'.repeat(4000), mid]));
  await h.ok('expired plus: shortening it works', () => h.q(`update messages set content = $1 where id = $2`, ['z'.repeat(3000), mid]));
  await h.fails('expired plus: growing it is refused', `update messages set content = $1 where id = $2`, ['z'.repeat(3001), mid]);
}
