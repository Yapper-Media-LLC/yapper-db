// 652: admin_set_plus_since. Only an admin sets a user's plus_since (any past date, or null to reset); each call
// writes a mod_log row 'plus_since_set' with the date. Future dates and unknown users are refused. No flag.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage589.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '652_admin_set_plus_since.sql'), 'utf8');

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`652 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  // Live shape (611): the column, readable by everyone, no table-level update for users.
  await h.db.exec(`alter table public.profiles add column if not exists plus_until timestamptz;
    alter table public.profiles add column if not exists plus_since timestamptz;
    revoke update on public.profiles from authenticated;
    grant update (username, bio) on public.profiles to authenticated;`);
  await h.ok('652 runs', () => h.db.exec(MIG));
  await h.ok('652 re-runs cleanly', () => h.db.exec(MIG));

  const antic = await h.signup('antic652@test.dev', 'antic652');
  const mod = await h.signup('mod652@test.dev', 'mod652');
  const member = await h.signup('member652@test.dev', 'member652');
  const target = await h.signup('target652@test.dev', 'target652');
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true)`, [mod]);
  const since = async () => (await h.one(`select plus_since from profiles where id = $1`, [target])).plus_since;
  const days = async () => (await h.one(`select round(extract(epoch from now() - plus_since) / 86400)::int d from profiles where id = $1`, [target])).d;

  await h.as(antic);
  await h.ok('admin sets plus_since 3 years back', () => h.q(`select admin_set_plus_since($1, now() - interval '3 years')`, [target]));
  await h.admin();
  h.eq('plus_since is about 3 years ago', Math.round((await days()) / 365), 3);
  let log = await h.one(`select actor, reason from mod_log where action = 'plus_since_set' and target_id = $1 order by created_at desc limit 1`, [target]);
  h.eq('logged by the admin', log.actor, antic);
  const expected = (await h.one(`select to_char(now() - interval '3 years', 'YYYY-MM-DD') d`)).d;
  h.eq('log carries the date', log.reason, expected);

  await h.as(antic);
  await h.ok('admin sets it on a user without Plus too', () => h.q(`select admin_set_plus_since($1, now() - interval '40 days')`, [target]));
  await h.admin();
  h.eq('date moved', await days(), 40);
  await h.as(antic);
  await h.ok('admin resets with null', () => h.q(`select admin_set_plus_since($1, null)`, [target]));
  await h.admin();
  h.eq('plus_since is null after reset', await since(), null);
  h.eq('reset is logged as such', (await h.one(`select reason from mod_log where action = 'plus_since_set' and target_id = $1 order by created_at desc limit 1`, [target])).reason, 'reset');
  h.eq('three log rows in all', (await h.one(`select count(*)::int n from mod_log where action = 'plus_since_set' and target_id = $1`, [target])).n, 3);

  await h.as(antic);
  await h.fails('a future date is refused', `select admin_set_plus_since($1, now() + interval '1 day')`, [target]);
  await h.fails('an unknown user is refused', `select admin_set_plus_since('00000000-0000-0000-0000-000000000001', now() - interval '1 day')`);
  await h.admin();
  h.eq('nothing logged for the refused calls', (await h.one(`select count(*)::int n from mod_log where action = 'plus_since_set'`)).n, 3);

  await h.as(mod);
  await h.fails('a head mod cannot set it', `select admin_set_plus_since($1, now() - interval '1 day')`, [target]);
  await h.as(member);
  await h.fails('a member cannot set it', `select admin_set_plus_since($1, now() - interval '1 day')`, [target]);
  await h.fails('a member cannot set their own', `select admin_set_plus_since($1, now() - interval '5 years')`, [member]);
  await h.fails('a member cannot write the column directly', `update profiles set plus_since = now() - interval '5 years' where id = $1`, [member]);
  await h.as(null);
  await h.fails('anon cannot set it', `select admin_set_plus_since($1, now() - interval '1 day')`, [target]);
  await h.admin();
  h.eq('still null after the refused calls', await since(), null);
}
