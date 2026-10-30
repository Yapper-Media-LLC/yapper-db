// 638: assigned moderators. Admins assign any regular mod to any active head mod; a head mod only takes mods for
// themselves and only unassigned or already-their mods; a plain mod sees their own row only; off-flag callers see
// nothing. Base and stand-ins as stage589, plus is_site_mod, then 638 on top.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage589.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(`create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null); $$;`);
  await h.db.exec(mig('638_assigned_mods.sql'));
  await h.ok('638 re-runs cleanly', () => h.db.exec(mig('638_assigned_mods.sql')));
  h.eq('flag row is in test mode', (await h.one(`select mode from feature_flags where key = 'assigned_mods'`)).mode, 'test');

  const antic = await h.signup('antic638@test.dev', 'antic638');
  const head1 = await h.signup('head1_638@test.dev', 'head1_638');
  const head2 = await h.signup('head2_638@test.dev', 'head2_638');
  const mod1 = await h.signup('mod1_638@test.dev', 'mod1_638');
  const mod2 = await h.signup('mod2_638@test.dev', 'mod2_638');
  const mod3 = await h.signup('mod3_638@test.dev', 'mod3_638');
  const outsider = await h.signup('out638@test.dev', 'out638'); // a mod outside the flag
  const member = await h.signup('member638@test.dev', 'member638');
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, true), ($3, false), ($4, false), ($5, false), ($6, false)`,
    [head1, head2, mod1, mod2, mod3, outsider]);
  // Flag: test mode, HQ test server. Everyone but the outsider is in it.
  const SID = '00000000-0000-4000-8000-00000000b001';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Test', $2)`, [SID, antic]);
  await h.q(`insert into server_members (server_id, user_id) select $1, unnest($2::uuid[]) on conflict do nothing`,
    [SID, [antic, head1, head2, mod1, mod2, mod3, member]]);

  // Flag off for the caller: nothing to see, nothing to do.
  await h.as(outsider);
  h.eq('mod outside the flag sees nothing', (await h.q(`select * from assigned_mods_list()`)).length, 0);
  await h.fails('mod outside the flag cannot assign', `select assign_mod_head($1, $2)`, [mod1, head1]);

  // Admin: anyone to anyone.
  await h.as(antic);
  await h.ok('admin assigns mod1 to head1', () => h.q(`select assign_mod_head($1, $2)`, [mod1, head1]));
  await h.fails('cannot assign a head mod', `select assign_mod_head($1, $2)`, [head2, head1]);
  await h.fails('cannot assign to a regular mod', `select assign_mod_head($1, $2)`, [mod2, mod3]);
  await h.fails('cannot assign a non-mod', `select assign_mod_head($1, $2)`, [member, head1]);
  let rows = await h.q(`select * from assigned_mods_list() order by user_id`);
  h.eq('admin sees every moderator', rows.length, 6);
  h.eq('mod1 is under head1', rows.find((r) => r.user_id === mod1).head_id, head1);
  h.eq('head rows are flagged', rows.find((r) => r.user_id === head1).head, true);
  h.eq('assignment is logged', (await h.one(`select count(*)::int as n from mod_log where action = 'mod_assigned' and target_id = $1 and actor = $2`, [mod1, antic])).n, 1);
  await h.ok('same assignment again is a no-op', () => h.q(`select assign_mod_head($1, $2)`, [mod1, head1]));
  h.eq('no second log row', (await h.one(`select count(*)::int as n from mod_log where action = 'mod_assigned' and target_id = $1`, [mod1])).n, 1);

  // Head mods: only to themselves, only unassigned or their own.
  await h.as(head2);
  await h.fails('head2 cannot take mod1 from head1', `select assign_mod_head($1, $2)`, [mod1, head2]);
  await h.fails('head2 cannot unassign a mod of head1', `select assign_mod_head($1, null)`, [mod1]);
  await h.fails('head2 cannot assign to head1', `select assign_mod_head($1, $2)`, [mod2, head1]);
  await h.ok('head2 takes unassigned mod2', () => h.q(`select assign_mod_head($1, $2)`, [mod2, head2]));
  await h.ok('head2 lets mod2 go', () => h.q(`select assign_mod_head($1, null)`, [mod2]));
  h.eq('unassign is logged', (await h.one(`select count(*)::int as n from mod_log where action = 'mod_unassigned' and target_id = $1 and actor = $2`, [mod2, head2])).n, 1);
  await h.ok('head2 takes mod2 again', () => h.q(`select assign_mod_head($1, $2)`, [mod2, head2]));
  rows = await h.q(`select * from assigned_mods_list()`);
  h.eq('head mod sees every moderator too', rows.length, 6);

  // Activity: actions in the last 7 days, last action.
  await h.admin();
  await h.q(`insert into mod_log (actor, action, target_id, created_at) values ($1, 'warn', $2, now() - interval '1 day'), ($1, 'ban', $2, now() - interval '2 days'), ($1, 'delete', $2, now() - interval '30 days')`, [mod1, member]);
  await h.as(head1);
  rows = await h.q(`select * from assigned_mods_list()`);
  h.eq('head sees 7-day action count', rows.find((r) => r.user_id === mod1).actions_7d, 2);
  h.eq('head sees last action', rows.find((r) => r.user_id === mod1).last_action !== null, true);

  // A plain mod: own row only, no counts.
  await h.as(mod1);
  rows = await h.q(`select * from assigned_mods_list()`);
  h.eq('plain mod sees only their own row', rows.map((r) => r.user_id), [mod1]);
  h.eq('plain mod sees their head mod', rows[0].head_id, head1);
  h.eq('plain mod gets no counts', rows[0].actions_7d, null);
  await h.fails('plain mod cannot assign', `select assign_mod_head($1, $2)`, [mod3, head1]);
  await h.fails('plain mod cannot read the table', `select * from mod_assignments`);

  // Not staff at all.
  await h.as(member);
  await h.fails('member cannot list', `select * from assigned_mods_list()`);
  await h.fails('member cannot assign', `select assign_mod_head($1, $2)`, [mod3, head1]);
  await h.as(null);
  await h.fails('anon cannot list', `select * from assigned_mods_list()`);

  // Paused head mod: loses their list and can't receive mods.
  await h.admin();
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [head2]);
  h.eq('paused head loses their mods', (await h.one(`select count(*)::int as n from mod_assignments where head_id = $1`, [head2])).n, 0);
  await h.as(antic);
  await h.fails('cannot assign to a paused head mod', `select assign_mod_head($1, $2)`, [mod3, head2]);

  // Losing head: the list goes with it. Becoming head: you leave your old list.
  await h.admin();
  await h.q(`update site_moderators set suspended_at = null where user_id = $1`, [head2]);
  await h.as(antic);
  await h.q(`select assign_mod_head($1, $2)`, [mod2, head2]);
  await h.admin();
  h.eq('unpaused head gets mods again', (await h.one(`select count(*)::int as n from mod_assignments where head_id = $1`, [head2])).n, 1);
  await h.q(`update site_moderators set head = false where user_id = $1`, [head2]);
  h.eq('demoted head loses their mods', (await h.one(`select count(*)::int as n from mod_assignments where head_id = $1`, [head2])).n, 0);
  await h.q(`update site_moderators set head = true where user_id = $1`, [mod1]);
  h.eq('a new head mod leaves their old list', (await h.one(`select count(*)::int as n from mod_assignments where user_id = $1`, [mod1])).n, 0);
  await h.q(`update site_moderators set head = false where user_id = $1`, [mod1]);
  await h.as(antic);
  await h.q(`select assign_mod_head($1, $2)`, [mod3, head1]);
  await h.admin();
  await h.q(`delete from site_moderators where user_id = $1`, [mod3]);
  h.eq('removed mod leaves the table', (await h.one(`select count(*)::int as n from mod_assignments where user_id = $1`, [mod3])).n, 0);
}
