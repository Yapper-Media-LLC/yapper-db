// Rehearses the filming rollout: start at stage 1 with real-looking data
// (two people chatting), then apply each later migration on top of that data,
// exactly like the video database will see it. After every step the old DM
// must still work and the new stage's main action must work.
// Usage: node tests/sql/rollout.dryrun.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setup, migrationFiles } from './harness.mjs';

const dir = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'supabase', 'migrations');
const h = await setup(1);

const pc = await h.signup('pc@test.dev', 'Antic');
const ipad = await h.signup('ipad@test.dev', 'AnticiPad');
await h.as(pc);
const dm = (await h.one(`select get_or_create_dm($1) id`, [ipad])).id;
await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'yo')`, [dm, pc]);
await h.as(ipad);
await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'hey from the ipad')`, [dm, ipad]);

let lastMsg;
async function chatStillWorks(step) {
  await h.as(pc);
  const r = await h.one(`insert into messages (channel_id, author_id, content) values ($1,$2,$3) returning id`, [dm, pc, `after ${step}`]);
  lastMsg = r.id;
  await h.as(ipad);
  const seen = (await h.q(`select content from messages where channel_id=$1`, [dm])).map((m) => m.content);
  h.eq(`${step}: old DM still readable + writable`, seen.includes(`after ${step}`) && seen.includes('yo'), true);
}

const actions = {
  2: async () => { await h.as(pc); await h.q(`update profiles set bio='i yap' where id=$1`, [pc]); },
  3: async () => {
    await h.as(pc);
    await h.q(`insert into emojis (owner_id, name, path, animated) values ($2, 'rat', $1, true)`, [`${pc}/rat.gif`, pc]);
  },
  4: async () => {
    await h.as(pc);
    await h.q(`update messages set content='edited!' where id=$1`, [lastMsg]);
    h.eq('stage 4: edited label', !!(await h.one(`select edited_at from messages where id=$1`, [lastMsg])).edited_at, true);
  },
  5: async () => {
    await h.as(pc);
    await h.q(`insert into messages (channel_id, author_id, content, attachment_path, attachment_width, attachment_height)
               values ($1,$2,'',$3,10,10)`, [dm, pc, `${pc}/pic.png`]);
  },
  6: async () => { await h.as(ipad); h.eq('stage 6: unread counts', (await h.q(`select * from unread_counts()`)).length > 0, true); await h.q(`select mark_read($1)`, [dm]); },
  7: async () => {
    await h.as(pc); await h.q(`select send_friend_request('AnticiPad')`);
    await h.as(ipad); await h.q(`select respond_friend_request($1, true)`, [pc]);
  },
  8: async () => {
    await h.as(pc);
    const g = (await h.one(`select create_group('the boys', null, array[$1]::uuid[]) id`, [ipad])).id;
    await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'group yap')`, [g, pc]);
  },
  9: async () => {
    await h.as(ipad);
    await h.q(`insert into messages (channel_id, author_id, content, reply_to_id) values ($1,$2,'replying',$3)`, [dm, ipad, lastMsg]);
    await h.q(`insert into reactions (message_id, user_id, emoji) values ($1,$2,'🔥')`, [lastMsg, ipad]);
  },
  10: async () => {
    await h.as(pc);
    const sid = (await h.one(`select create_server('Yapper HQ', null) id`)).id;
    await h.q(`insert into invites (code, server_id, created_by) values ('film1234', $1, $2)`, [sid, pc]);
    await h.as(ipad);
    await h.q(`select join_server('film1234')`);
  },
  11: async () => {
    await h.as(pc);
    const sid = (await h.one(`select id from servers limit 1`)).id;
    await h.q(`select create_channel($1, 'Chill', 'voice')`, [sid]);
    h.eq('stage 11: voice channels exist', (await h.q(`select id from channels where server_id=$1 and kind='voice'`, [sid])).length >= 1, true);
  },
};

const done = new Set();
for (const f of migrationFiles().filter((x) => parseInt(x, 10) > 1)) {
  const n = parseInt(f, 10);
  await h.admin();
  try {
    await h.db.exec(readFileSync(join(dir, f), 'utf8'));
  } catch (e) {
    console.log(`✗ ${f} failed on a database with data: ${e.message}`);
    process.exit(1);
  }
  await chatStillWorks(f);
  try {
    if (!done.has(n)) await actions[n]?.();
    done.add(n);
  } catch (e) {
    console.log(`✗ stage ${n} action: ${e.message}`);
    process.exit(1);
  }
  console.log(`✓ ${f} applied on top of live data`);
}
console.log(`rollout rehearsal passed (${h.passed} checks)`);
