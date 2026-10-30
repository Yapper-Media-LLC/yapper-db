// 641: missed calls in the chat (flag missed_calls). Base 24 + the flag migrations, a stand-in for Supabase's
// realtime.broadcast_changes (062's bc_call trigger calls it), 062 for calls, then 641.
// Checks: a DM call that ends unanswered leaves one "Missed call" line from the caller (system kind call_missed),
// ringing again within a minute adds no second line, a call someone picked up leaves "Call, N min" with the seconds,
// call_joined only works for a member who isn't the caller, start_call clears answered_at, nobody can write or change
// messages.system from the client, and the flag gates it (off = nothing written).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('641_missed_calls.sql');

const STANDINS = `
create schema if not exists realtime;
create or replace function realtime.broadcast_changes(topic text, event text, operation text, table_name text, table_schema text, new record, old record)
  returns void language plpgsql as $$ begin return; end $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`641 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('062_calls.sql'));
  await h.ok('641 applies', () => h.db.exec(MIG));
  await h.ok('641 re-runs cleanly', () => h.db.exec(MIG));

  const caller = await h.signup('caller@x.y', 'caller');
  const callee = await h.signup('callee@x.y', 'callee');
  const stranger = await h.signup('stranger@x.y', 'stranger');
  await h.admin();
  // Accounts older than an hour: the new-account "one message every 3 seconds" rule would otherwise refuse the
  // second line (and the trigger swallows that on purpose, see the last check).
  await h.q(`update public.profiles set created_at = now() - interval '2 hours' where id in ($1, $2)`, [caller, callee]);
  const dm = (await h.one(`insert into public.channels (kind, dm_key, created_by) values ('dm', $1, $2) returning id`,
    [[caller, callee].sort().join(':'), caller])).id;
  await h.q(`insert into public.channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, caller, callee]);
  // Test group: only the caller (the callee is in it by being in the same DM).
  await h.q(`update public.feature_flags set users = array[$1::uuid], servers = '{}' where key = 'missed_calls'`, [caller]);
  h.eq('flag row in test mode', (await h.one(`select mode from public.feature_flags where key = 'missed_calls'`)).mode, 'test');

  const notes = () => h.q(`select author_id, content, system from public.messages where channel_id = $1 order by created_at`, [dm]);
  // Make every line in the chat two minutes old (the edit guard pins created_at, so it steps aside for a moment).
  const age = async () => {
    await h.admin();
    await h.db.exec(`alter table public.messages disable trigger messages_edit_guard`);
    await h.q(`update public.messages set created_at = now() - interval '2 minutes' where channel_id = $1`, [dm]);
    await h.db.exec(`alter table public.messages enable trigger messages_edit_guard`);
  };

  // ---- missed ----
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.admin();
  h.eq('new call starts unanswered', (await h.one(`select answered_at from public.calls where channel_id = $1`, [dm])).answered_at, null);
  await h.as(caller);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  let rows = await notes();
  h.eq('one missed-call line from the caller', rows.map((r) => [r.author_id, r.content, r.system]), [[caller, 'Missed call', { kind: 'call_missed' }]]);

  // Rings again right away and gives up again: no second line within a minute.
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  h.eq('no second line within a minute', (await notes()).length, 1);
  // An older line doesn't block a new one.
  await age();
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  h.eq('a later miss gets its own line', (await notes()).length, 2);
  await age();

  // ---- answered ----
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.q(`select public.call_joined($1)`, [dm]);
  await h.admin();
  h.eq('the caller joining is not an answer', (await h.one(`select answered_at from public.calls where channel_id = $1`, [dm])).answered_at, null);
  await h.as(stranger);
  await h.q(`select public.call_joined($1)`, [dm]);
  await h.admin();
  h.eq('a stranger cannot mark it answered', (await h.one(`select answered_at from public.calls where channel_id = $1`, [dm])).answered_at, null);
  await h.as(callee);
  await h.q(`select public.call_joined($1)`, [dm]);
  await h.admin();
  h.eq('the other person joining answers it', (await h.one(`select answered_at is not null as a from public.calls where channel_id = $1`, [dm])).a, true);
  // The call ran 12 minutes (the webhook's own update works the same way as call_joined: a direct column write).
  await h.q(`update public.calls set answered_at = now() - interval '12 minutes 5 seconds' where channel_id = $1`, [dm]);
  await h.as(callee);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  rows = await notes();
  const last = rows[rows.length - 1];
  h.eq('answered call leaves a duration line from the caller', [rows.length, last.author_id, last.content, last.system.kind], [3, caller, 'Call, 12 min', 'call']);
  h.eq('seconds are recorded', last.system.secs >= 725 && last.system.secs < 730, true);

  // A short call reads in seconds.
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.admin();
  h.eq('start_call clears answered_at', (await h.one(`select answered_at from public.calls where channel_id = $1`, [dm])).answered_at, null);
  await h.q(`update public.calls set answered_at = now() - interval '40 seconds' where channel_id = $1`, [dm]);
  await h.as(caller);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  rows = await notes();
  h.eq('short call reads in seconds', rows[rows.length - 1].content, 'Call, 40 sec');

  // ---- nobody fakes system ----
  await h.as(callee);
  const fake = (await h.one(`insert into public.messages (channel_id, author_id, content, system) values ($1, $2, 'Missed call', '{"kind":"call_missed"}') returning system`, [dm, callee])).system;
  h.eq('a client insert cannot set system', fake, null);
  await h.as(caller);
  await h.q(`update public.messages set system = '{"kind":"call_missed"}' where channel_id = $1 and author_id = $2 and system is null`, [dm, caller]);
  await h.q(`update public.messages set system = '{"kind":"x"}' where channel_id = $1 and author_id = $2 and system is not null`, [dm, caller]);
  await h.admin();
  h.eq('system never changes after insert', (await h.q(`select distinct system ->> 'kind' as k from public.messages where channel_id = $1 and system is not null order by 1`, [dm])).map((r) => r.k), ['call', 'call_missed']);
  h.eq('no system mark was added by a client', (await h.one(`select count(*)::int as n from public.messages where channel_id = $1 and system is not null`, [dm])).n, 4);
  await h.as(null);
  await h.fails('anon cannot call call_joined', `select public.call_joined('${dm}')`);
  await h.admin();

  // ---- flag off: nothing written ----
  await h.q(`update public.feature_flags set mode = 'off' where key = 'missed_calls'`);
  const before = (await notes()).length;
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  h.eq('flag off writes nothing', (await notes()).length, before);
  // Test mode with the callee's server in the group counts too (either side of the DM).
  const srv = (await h.one(`insert into public.servers (name, owner_id) values ('t', $1) returning id`, [callee])).id;
  await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [srv, callee]);
  await h.q(`update public.feature_flags set mode = 'test', users = '{}', servers = array[$1::uuid] where key = 'missed_calls'`, [srv]);
  await age();
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  h.eq('test group via the other person counts', (await notes()).length, before + 1);

  // A guard refusing the line (a brand-new account that just typed, 3-second rule) never stops the call from ending.
  await age();
  await h.q(`update public.profiles set created_at = now() where id = $1`, [caller]);
  await h.as(caller);
  await h.q(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'hey') returning id`, [dm, caller]);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.ok('end_call survives a refused line', () => h.q(`select public.end_call($1)`, [dm]));
  await h.admin();
  h.eq('the call still ended', (await h.one(`select ended_at is not null as e from public.calls where channel_id = $1`, [dm])).e, true);
  h.eq('and no line was written', (await h.one(`select count(*)::int as n from public.messages where channel_id = $1 and system is not null and created_at > now() - interval '30 seconds'`, [dm])).n, 0);
}
