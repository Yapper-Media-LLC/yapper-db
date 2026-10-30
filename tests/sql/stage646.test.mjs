// 646: the call line records how long it rang. Same setup as stage641 (base 24 + flags, realtime stand-in, 062, 641),
// then 646. Checks: a missed call carries rang (ring start to end), an answered one carries secs and rang (ring start
// to pickup), the trigger is still the only writer, and the file re-runs.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('646_call_note_rang.sql');

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`646 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(`create schema if not exists realtime;
    create or replace function realtime.broadcast_changes(topic text, event text, operation text, table_name text, table_schema text, new record, old record)
      returns void language plpgsql as $$ begin return; end $$;`);
  await h.db.exec(mig('062_calls.sql'));
  await h.db.exec(mig('641_missed_calls.sql'));
  await h.ok('646 applies', () => h.db.exec(MIG));
  await h.ok('646 re-runs cleanly', () => h.db.exec(MIG));

  const caller = await h.signup('caller@x.y', 'caller');
  const callee = await h.signup('callee@x.y', 'callee');
  await h.admin();
  await h.q(`update public.profiles set created_at = now() - interval '2 hours' where id in ($1, $2)`, [caller, callee]);
  const dm = (await h.one(`insert into public.channels (kind, dm_key, created_by) values ('dm', $1, $2) returning id`,
    [[caller, callee].sort().join(':'), caller])).id;
  await h.q(`insert into public.channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, caller, callee]);
  await h.q(`update public.feature_flags set users = array[$1::uuid], servers = '{}' where key = 'missed_calls'`, [caller]);
  const notes = () => h.q(`select author_id, content, system from public.messages where channel_id = $1 order by created_at`, [dm]);

  // Missed after ringing 28 s.
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.admin();
  await h.q(`update public.calls set started_at = now() - interval '28 seconds' where channel_id = $1`, [dm]);
  await h.as(caller);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  let rows = await notes();
  h.eq('missed line carries kind and rang', [rows.length, rows[0].author_id, rows[0].content, rows[0].system.kind, rows[0].system.rang], [1, caller, 'Missed call', 'call_missed', 28]);

  // Answered after 9 s, talked 5 minutes.
  await h.db.exec(`alter table public.messages disable trigger messages_edit_guard`);
  await h.q(`update public.messages set created_at = now() - interval '2 minutes' where channel_id = $1`, [dm]);
  await h.db.exec(`alter table public.messages enable trigger messages_edit_guard`);
  await h.as(caller);
  await h.q(`select public.start_call($1)`, [dm]);
  await h.as(callee);
  await h.q(`select public.call_joined($1)`, [dm]);
  await h.admin();
  await h.q(`update public.calls set started_at = now() - interval '5 minutes 9 seconds', answered_at = now() - interval '5 minutes' where channel_id = $1`, [dm]);
  await h.as(callee);
  await h.q(`select public.end_call($1)`, [dm]);
  await h.admin();
  rows = await notes();
  const last = rows[rows.length - 1];
  h.eq('answered line carries secs and rang', [rows.length, last.content, last.system.kind, last.system.rang, last.system.secs >= 300 && last.system.secs < 305], [2, 'Call, 5 min', 'call', 9, true]);

  await h.as(callee);
  const fake = (await h.one(`insert into public.messages (channel_id, author_id, content, system) values ($1, $2, 'x', '{"kind":"call_missed","rang":1}') returning system`, [dm, callee])).system;
  h.eq('a client still cannot set system', fake, null);
}
