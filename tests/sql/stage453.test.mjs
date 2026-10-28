// 453: bots join voice (flag bot_voice_join). bot_voice_join_gate (in server, flag on for that server, 10 joins and
// leaves a minute) and the new bot_voice_event: a bot hears about itself where the flag is on, and a bot joining or
// leaving is sent to the realtime server (public.bc, stubbed here into a table) so it shows in the voice list.
// Starts from stage184's stand-ins and live definitions, then 184, then 453.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS, LIVE } from './stage184.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;

const BC = `
create table if not exists public.bc_log (topic text, event text, rec jsonb);
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
returns void language plpgsql security definer set search_path = public as $$
begin insert into public.bc_log values (topic_name, event_name, to_jsonb(new)); end $$;
`;

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(BC);
  await h.db.exec(mig('184_bot_voice.sql'));
  const MIG = mig('453_bot_voice_join.sql');
  await h.ok('453 runs', () => h.db.exec(MIG));
  await h.ok('453 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('no plain drop / delete-from in the file (Supabase MCP hangs on them)', /\bdrop\s|\bdelete\s+from\b/i.test(MIG), false);
  h.eq('no em dashes', MIG.includes('—'), false);
  h.eq('flag added in test mode for the HQ server only', await h.one(`select mode, servers, users from feature_flags where key = 'bot_voice_join'`),
    { mode: 'test', servers: ['00000000-0000-4000-8000-00000000b001'], users: [] });

  const err = async (sql, params = []) => { try { await h.db.query(sql, params); return null; } catch (e) { return e; } };

  const owner = await h.signup('owner@test.dev', 'owner');
  const alice = await h.signup('alice@test.dev', 'alice');
  const botA = await h.signup('bota@test.dev', 'bot_a');
  const botB = await h.signup('botb@test.dev', 'bot_b');
  await h.as(owner);
  const sid = (await h.one(`select create_server('Voice', null) id`)).id;
  const other = (await h.one(`select create_server('Other', null) id`)).id;
  await h.admin();
  const vc = (await h.one(`select id from channels where server_id = $1 and kind = 'voice' limit 1`, [sid])).id;
  const otherVc = (await h.one(`select id from channels where server_id = $1 and kind = 'voice' limit 1`, [other])).id;
  await h.q(`insert into bots (id, owner_id) values ($1, $3), ($2, $3)`, [botA, botB, owner]);
  await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $3), ($2, $3), ($1, $4)`, [botA, botB, sid, other]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'bot_voice'`);

  const gate = async (bid, s) => { await h.admin(); return (await h.one(`select bot_voice_join_gate($1, $2) r`, [bid, s])).r; };
  const event = async (cid, uid, ev) => { await h.admin(); return (await h.one(`select bot_voice_event($1, $2, $3) n`, [cid, uid, ev])).n; };
  const events = async () => { await h.admin(); return h.q(`select bot_id, type, data from bot_events order by id`); };
  const pres = async () => { await h.admin(); return h.q(`select topic, event, rec from bc_log`); };
  const clear = async () => { await h.admin(); await h.q(`delete from bot_events`); await h.q(`delete from bc_log`); };

  // ---- gate ----
  h.eq('gate: bot not in that server', await gate(botB, other), 'The bot is not in that server');
  h.eq('gate: flag off for an unlisted server', await gate(botA, sid), 'Bots can\'t join voice in this server yet');
  h.eq('a refused gate counts nothing', (await h.one(`select count(*)::int n from bot_voice_rate`)).n, 0);
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'bot_voice_join'`, [botA]);
  h.eq('gate: listing users does not turn it on for a server', await gate(botA, sid), 'Bots can\'t join voice in this server yet');
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'bot_voice_join'`, [sid]);
  h.eq('gate: on for a listed server', await gate(botA, sid), null);
  h.eq('gate: still off for another server', await gate(botA, other), 'Bots can\'t join voice in this server yet');
  let last = null;
  for (let i = 0; i < 9; i++) last = await gate(botA, sid);
  h.eq('10 joins and leaves a minute are fine', last, null);
  h.eq('the 11th is refused', await gate(botA, sid), 'Slow down: 10 voice joins and leaves a minute per bot');
  h.eq('own bucket: moves untouched', (await h.one(`select n, read_n from bot_voice_rate where bot_id = $1`, [botA])), { n: 0, read_n: 0 });
  h.eq('moves still allowed', (await h.one(`select bot_voice_gate($1, $2, true) r`, [botA, sid])).r, null);
  h.eq('moves did not touch the join count', (await h.one(`select join_n from bot_voice_rate where bot_id = $1`, [botA])).join_n, 11);
  await h.q(`update bot_voice_rate set join_window_start = now() - interval '61 seconds' where bot_id = $1`, [botA]);
  h.eq('a minute later joins start over', await gate(botA, sid), null);
  h.eq('another bot has its own count', await gate(botB, sid), null);
  const leave = async (bid, s) => { await h.admin(); return (await h.one('select bot_voice_join_gate($1, $2, true) r', [bid, s])).r; };
  h.eq('leaving works where the flag is off', await leave(botA, other), null);
  await h.q('delete from bot_servers where bot_id = $1 and server_id = $2', [botB, sid]);
  h.eq('a kicked bot can still leave', await leave(botB, sid), null);
  h.eq('but not join', await gate(botB, sid), 'The bot is not in that server');
  for (let i = 0; i < 8; i++) await leave(botB, sid);   // 1 join + 1 leave so far
  h.eq('leaves count toward the 10 a minute', await leave(botB, sid), 'Slow down: 10 voice joins and leaves a minute per bot');
  await h.q('insert into bot_servers (bot_id, server_id) values ($1, $2)', [botB, sid]);

  // ---- events about the bot itself ----
  await clear();
  h.eq('bot joins: itself and the other bot hear it', await event(vc, botA, 'voice_join'), 2);
  h.eq('both got voice_join', (await events()).map((e) => [e.bot_id, e.type, e.data.user_id]).sort((a, b) => a[0].localeCompare(b[0])),
    [[botA, 'voice_join', botA], [botB, 'voice_join', botA]].sort((a, b) => a[0].localeCompare(b[0])));
  h.eq('presence sent to the server topic', (await pres()).map((p) => [p.topic, p.event, p.rec.user_id, p.rec.server_id, p.rec.channel_id, p.rec.joined]),
    [[`server:${sid}`, 'bot_voice', botA, sid, vc, true]]);

  await clear();
  h.eq('a person joining: no presence message', [await event(vc, alice, 'voice_join'), (await pres()).length], [2, 0]);

  await clear();
  h.eq('flag off server: bot gets nothing about itself', await event(otherVc, botA, 'voice_join'), 0);
  h.eq('flag off server: no presence for a join', (await pres()).length, 0);
  h.eq('flag off server: a leave still clears presence', [await event(otherVc, botA, 'voice_leave'), (await pres()).map((p) => p.rec.joined)], [0, [false]]);

  await clear();
  await h.q(`update feature_flags set mode = 'off' where key = 'bot_voice'`);
  h.eq('bot_voice off: no events, presence still sent', [await event(vc, botA, 'voice_leave'), (await pres()).map((p) => p.rec.joined)], [0, [false]]);

  // ---- service role only ----
  await h.as(owner);
  h.eq('members cannot call bot_voice_join_gate', !!(await err(`select bot_voice_join_gate($1, $2, false)`, [botA, sid])), true);
  h.eq('members cannot call bot_voice_event', !!(await err(`select bot_voice_event($1, $2, 'voice_join')`, [vc, botA])), true);
  await h.as(null);
  h.eq('anon cannot call bot_voice_join_gate', !!(await err(`select bot_voice_join_gate($1, $2)`, [botA, sid])), true);
  await h.admin();
  h.eq('security definer with search_path set', (await h.q(`select proname, prosecdef, proconfig from pg_proc where proname in ('bot_voice_join_gate', 'bot_voice_event') order by proname`)).map((r) => [r.proname, r.prosecdef, r.proconfig]),
    [['bot_voice_event', true, ['search_path=public']], ['bot_voice_join_gate', true, ['search_path=public']]]);
}
