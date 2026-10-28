// 478: reaction rate limit (20 per 10 s, 100 per 5 min per account). NOT applied (database freeze Oct 25).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '478_reaction_rate_limit.sql'), 'utf8');
export const base = 24;

export default async function (h) {
  await h.admin();
  await h.ok('478 runs', () => h.db.exec(MIG));
  await h.ok('478 re-runs cleanly', () => h.db.exec(MIG));

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [a])).id;
  const cid = (await h.one(`insert into channels (kind, name, server_id, created_by, position) values ('text', 'c', $1, $2, 0) returning id`, [sid, a])).id;
  const msgs = [];
  // Message triggers (new account slowmode) are off while the test makes its messages.
  await h.db.exec(`set session_replication_role = replica`);
  for (let i = 0; i < 30; i++) msgs.push((await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi') returning id`, [cid, a])).id);
  await h.db.exec(`set session_replication_role = origin`);

  // Signed in as someone (auth.uid() set) but past RLS, so this checks the trigger alone.
  const asUid = async (uid) => { await h.admin(); await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [uid]); };
  const react = (uid, mid, e = '👍') => h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, $3)`, [mid, uid, e]);

  await asUid(b);
  for (let i = 0; i < 20; i++) await react(b, msgs[i]);
  h.eq('20 in a burst are fine', Number((await h.one(`select count(*) n from reactions where user_id = $1`, [b])).n), 20);
  await h.fails('the 21st within 10 s is refused', `insert into reactions (message_id, user_id, emoji) values ($1, $2, '👍')`, [msgs[20], b]);
  h.eq('error says slow down', await react(b, msgs[21]).then(() => 'ok', (e) => e.message), 'Slow down, you\'re reacting too fast. Try again in a bit.');

  // Other people aren't affected.
  await asUid(a);
  await h.ok('someone else can still react', () => react(a, msgs[0]));

  // Review fix: a backdated created_at from the client doesn't skip the windows (the trigger stamps now()).
  const backdated = (mid) => h.q(`insert into reactions (message_id, user_id, emoji, created_at) values ($1, $2, '🔥', '2000-01-01')`, [mid, a]);
  for (let i = 1; i < 20; i++) await backdated(msgs[i]);
  h.eq('backdated rows are stamped now', Number((await h.one(`select count(*) n from reactions where user_id = $1 and created_at > now() - interval '1 minute'`, [a])).n), 20);
  await h.fails('the 21st backdated one is refused too', `insert into reactions (message_id, user_id, emoji, created_at) values ($1, $2, '🔥', '2000-01-01')`, [msgs[20], a]);

  // After 10 s the short window clears; the 5 minute one still counts.
  await h.admin();
  await h.q(`update reactions set created_at = now() - interval '11 seconds' where user_id = $1`, [b]);
  await asUid(b);
  await h.ok('short window clears after 10 s', () => react(b, msgs[22]));

  await h.admin();
  await h.q(`update reactions set created_at = now() - interval '1 minute' where user_id = $1`, [b]);
  // 21 rows now; fill to 100 within 5 minutes using other emoji, backdated past the 10 s window.
  for (let i = 0; i < 79; i++) {
    await h.q(`insert into reactions (message_id, user_id, emoji, created_at) values ($1, $2, $3, now() - interval '1 minute')`,
      [msgs[i % 30], b, ['😀', '😂', '🔥', '❤️'][Math.floor(i / 30)] ?? '🎉']);
  }
  await asUid(b);
  await h.fails('101st within 5 min is refused', `insert into reactions (message_id, user_id, emoji) values ($1, $2, '🙂')`, [msgs[29], b]);

  // System inserts (no auth.uid(), or yapper.bot) skip it.
  await h.admin();
  await h.ok('no signed-in user: skipped', () => react(b, msgs[29], '🙂'));
  await asUid(b);
  await h.db.exec(`select set_config('yapper.bot', '1', false)`);
  await h.ok('yapper.bot: skipped', () => react(b, msgs[29], '😎'));
  await h.db.exec(`select set_config('yapper.bot', '', false)`);
}
