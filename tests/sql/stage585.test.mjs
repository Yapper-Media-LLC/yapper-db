// 585: new accounts earn Shards after 1 day instead of 3. Runs 468's whole test first (same base and stand-ins),
// then 585 on top: a day-old account earns and claims, a twelve-hour-old one still can't, the refusal says "a day".
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
  const MIG = mig('585_shards_1day.sql');
  await h.ok('585 runs', () => h.db.exec(MIG));
  await h.ok('585 re-runs cleanly', () => h.db.exec(MIG));
  const cfg = (await h.one(`select shard_config() c`)).c;
  h.eq('min age is 1 day', cfg.min_age_days, 1);
  h.eq('invite and buyer ages untouched', [cfg.invite_age_days, cfg.buyer_age_days, cfg.invite_active_days], [7, 7, 3]);

  const dayold = await h.signup('dayold585@test.dev', 'dayold585');
  const hours = await h.signup('hours585@test.dev', 'hours585');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '25 hours', avatar_path = id::text || '/a.png', bio = 'x' where id = $1`, [dayold]);
  await h.q(`update profiles set created_at = now() - interval '12 hours', avatar_path = id::text || '/a.png', bio = 'x' where id = $1`, [hours]);
  await h.q(`update feature_flags set mode = 'everyone' where key in ('shards', 'shard_quests')`);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Day', $1) returning id`, [dayold])).id;
  const chan = (await h.one(`insert into channels (kind, name, server_id, created_by, position) values ('text', 'general', $1, $2, 0) returning id`, [sid, dayold])).id;
  await h.db.exec(`set session_replication_role = replica`);
  try {
    await h.q(`insert into messages (channel_id, author_id, content, created_at) select $1, u, 'hi', date_trunc('day', now() at time zone 'utc') at time zone 'utc' + interval '1 minute' from unnest($2::uuid[]) u`, [chan, [dayold, hours]]);
  } finally { await h.db.exec(`set session_replication_role = origin`); }
  const boost = Number((await h.one(`select shard_boost($1) b`, [dayold])).b);

  await h.as(dayold);
  h.eq('a day-old account earns the daily', (await h.one(`select shards_tick() r`)).r.balance, 5 * boost);
  const claimed = (await h.one(`select claim_shard_quest('profile') r`)).r;
  h.ok('a day-old account claims a quest', async () => { if (!claimed) throw new Error('no claim'); });

  await h.as(hours);
  h.eq('twelve hours old: nothing', (await h.one(`select shards_tick() r`)).r.balance, 0);
  let msg = '';
  try { await h.q(`select claim_shard_quest('profile')`); } catch (e) { msg = e.message; }
  h.eq('twelve hours old: can not claim, and the text says a day', msg.includes('needs to be a day old'), true);
}
