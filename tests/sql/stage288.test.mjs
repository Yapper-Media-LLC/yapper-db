// 288: call_e2ee(cid) answers per room, the same for everyone in it. Server voice: the server is in the flag's servers.
// DM / group: anyone in the chat is a flag user (not a flag server member: that would leak private test servers). Off for people who can't see the call.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '288_call_e2ee.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(`create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
    mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');`);
  await h.db.exec(MIG);
  await h.ok('288 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag made in test mode', (await h.one(`select mode from feature_flags where key = 'call_e2ee'`)).mode, 'test');

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  const testSid = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [amy])).id;
  const otherSid = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [bob])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($3, $4), ($3, $5) on conflict do nothing`, [testSid, amy, otherSid, bob, cat]);
  const testVc = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('vc', 'voice', $1, $2) returning id`, [testSid, amy])).id;
  const otherVc = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('vc', 'voice', $1, $2) returning id`, [otherSid, bob])).id;
  const dm = async (a, b) => {
    const c = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', $2, $1) returning id`, [a, a + ':' + b])).id;
    await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [c, a, b]);
    return c;
  };
  const amyBob = await dm(amy, bob);
  const bobCat = await dm(bob, cat);
  const ask = async (who, cid) => { await h.as(who); const r = (await h.one(`select call_e2ee($1) v`, [cid])).v; await h.admin(); return r; };

  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'call_e2ee'`, [testSid]);
  h.eq('test server voice is encrypted', await ask(amy, testVc), true);
  h.eq('other server voice is not', await ask(bob, otherVc), false);
  h.eq('DM with a test server member stays off (no leak of who is in test servers)', await ask(bob, amyBob), false);
  h.eq('someone outside the server gets false', await ask(cat, testVc), false);
  const text = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('chat', 'text', $1, $2) returning id`, [testSid, amy])).id;
  h.eq('a text channel is never a call', await ask(amy, text), false);

  await h.q(`update feature_flags set servers = '{}', users = array[$1::uuid] where key = 'call_e2ee'`, [cat]);
  h.eq('flag user in a DM turns it on for both (per room, not per person)', [await ask(bob, bobCat), await ask(cat, bobCat)], [true, true]);
  h.eq('DM without the flag user is off', await ask(amy, amyBob), false);
  h.eq('someone outside the call gets false', await ask(amy, bobCat), false);
  const grp = (await h.one(`insert into channels (kind, name, created_by) values ('group', 'g', $1) returning id`, [amy])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3), ($1, $4)`, [grp, amy, bob, cat]);
  h.eq('group with the flag user: on for everyone in it', [await ask(amy, grp), await ask(bob, grp)], [true, true]);
  h.eq('a flag user does not turn on a server voice channel by being in it', await ask(bob, otherVc), false);

  await h.q(`update feature_flags set mode = 'everyone', users = '{}' where key = 'call_e2ee'`);
  h.eq('everyone mode: every call', [await ask(bob, otherVc), await ask(amy, amyBob)], [true, true]);
  await h.q(`update feature_flags set mode = 'off' where key = 'call_e2ee'`);
  h.eq('off: none', await ask(amy, testVc), false);

  await h.as(null);
  await h.fails('anon can\'t call it', `select call_e2ee($1)`, [testVc]);
}
