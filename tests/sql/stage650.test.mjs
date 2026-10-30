// 650: Management and head mods assign like admins. Any lead (admin, manager, head mod) puts any regular mod under
// any active head mod and takes them off again; managers see the whole list. Still: only regular mods, only active
// head mods as targets, a log row per change, nothing outside the flag. Same base as stage638, then 638 and 650.
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
  await h.db.exec(mig('650_team_assign_managers.sql'));
  await h.ok('650 re-runs cleanly', () => h.db.exec(mig('650_team_assign_managers.sql')));
  h.eq('flag stays in test mode', (await h.one(`select mode from feature_flags where key = 'assigned_mods'`)).mode, 'test');

  const antic = await h.signup('antic650@test.dev', 'antic650');
  const mgr = await h.signup('mgr650@test.dev', 'mgr650'); // Management: a head mod with a site_managers row
  const head1 = await h.signup('head1_650@test.dev', 'head1_650');
  const head2 = await h.signup('head2_650@test.dev', 'head2_650');
  const mod1 = await h.signup('mod1_650@test.dev', 'mod1_650');
  const mod2 = await h.signup('mod2_650@test.dev', 'mod2_650');
  const mod3 = await h.signup('mod3_650@test.dev', 'mod3_650');
  const outsider = await h.signup('out650@test.dev', 'out650'); // a head mod outside the flag
  const member = await h.signup('member650@test.dev', 'member650');
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, true), ($3, true), ($4, false), ($5, false), ($6, false), ($7, true)`,
    [mgr, head1, head2, mod1, mod2, mod3, outsider]);
  await h.q(`insert into site_managers (user_id) values ($1)`, [mgr]);
  const SID = '00000000-0000-4000-8000-00000000b001';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Test', $2)`, [SID, antic]);
  await h.q(`insert into server_members (server_id, user_id) select $1, unnest($2::uuid[]) on conflict do nothing`,
    [SID, [antic, mgr, head1, head2, mod1, mod2, mod3, member]]);

  // Outside the flag: nothing, even for a head mod.
  await h.as(outsider);
  h.eq('head mod outside the flag sees nothing', (await h.q(`select * from assigned_mods_list()`)).length, 0);
  await h.fails('head mod outside the flag cannot assign', `select assign_mod_head($1, $2)`, [mod1, head1]);

  // A head mod: any mod to any active head mod, and off again.
  await h.as(head1);
  await h.ok('head1 puts mod1 under head2', () => h.q(`select assign_mod_head($1, $2)`, [mod1, head2]));
  await h.ok('head1 moves mod1 from head2 to themselves', () => h.q(`select assign_mod_head($1, $2)`, [mod1, head1]));
  await h.ok('head1 moves mod1 back to head2', () => h.q(`select assign_mod_head($1, $2)`, [mod1, head2]));
  h.eq('each move is logged', (await h.one(`select count(*)::int as n from mod_log where action = 'mod_assigned' and target_id = $1 and actor = $2`, [mod1, head1])).n, 3);
  h.eq('log says where to', (await h.one(`select reason from mod_log where action = 'mod_assigned' and target_id = $1 order by created_at desc limit 1`, [mod1])).reason, 'to head2_650');
  await h.ok('head1 takes mod1 off head2 list', () => h.q(`select assign_mod_head($1, null)`, [mod1]));
  h.eq('unassign is logged', (await h.one(`select count(*)::int as n from mod_log where action = 'mod_unassigned' and target_id = $1 and actor = $2`, [mod1, head1])).n, 1);
  await h.ok('unassigning again is a no-op', () => h.q(`select assign_mod_head($1, null)`, [mod1]));
  h.eq('no second unassign row', (await h.one(`select count(*)::int as n from mod_log where action = 'mod_unassigned' and target_id = $1`, [mod1])).n, 1);
  await h.fails('head mod cannot assign a head mod', `select assign_mod_head($1, $2)`, [head2, head1]);
  await h.fails('head mod cannot assign to a regular mod', `select assign_mod_head($1, $2)`, [mod2, mod3]);
  await h.fails('head mod cannot assign a non-mod', `select assign_mod_head($1, $2)`, [member, head1]);
  // The flag gates the caller, not the target: an active head mod outside the flag can still get mods.
  await h.ok('head mod assigns to the head mod outside the flag', () => h.q(`select assign_mod_head($1, $2)`, [mod2, outsider]));
  await h.admin();
  h.eq('a flagged-off head mod is still a valid target', (await h.one(`select count(*)::int as n from mod_assignments where user_id = $1 and head_id = $2`, [mod2, outsider])).n, 1);

  // Management: sees everyone and assigns like an admin.
  await h.as(mgr);
  let rows = await h.q(`select * from assigned_mods_list()`);
  h.eq('manager sees every moderator', rows.length, 7);
  h.eq('manager gets the counts', rows.find((r) => r.user_id === mod1).actions_7d, 0);
  await h.ok('manager moves mod2 from the outsider to head1', () => h.q(`select assign_mod_head($1, $2)`, [mod2, head1]));
  await h.ok('manager puts mod3 under head2', () => h.q(`select assign_mod_head($1, $2)`, [mod3, head2]));
  await h.ok('manager takes mod3 off', () => h.q(`select assign_mod_head($1, null)`, [mod3]));
  h.eq('manager assignments are logged with their id', (await h.one(`select count(*)::int as n from mod_log where actor = $1 and action in ('mod_assigned', 'mod_unassigned')`, [mgr])).n, 3);
  await h.admin();
  h.eq('assigned_by is the manager', (await h.one(`select assigned_by from mod_assignments where user_id = $1`, [mod2])).assigned_by, mgr);
  await h.as(mgr);
  await h.fails('manager cannot assign a head mod', `select assign_mod_head($1, $2)`, [head1, head2]);
  await h.fails('manager cannot assign to a regular mod', `select assign_mod_head($1, $2)`, [mod3, mod1]);

  // Admin still works; a paused head mod is no target.
  await h.as(antic);
  await h.ok('admin puts mod3 under head1', () => h.q(`select assign_mod_head($1, $2)`, [mod3, head1]));
  await h.admin();
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [head2]);
  await h.as(head1);
  await h.fails('cannot assign to a paused head mod', `select assign_mod_head($1, $2)`, [mod1, head2]);

  // A plain mod: own row, no assigning. Non-staff: nothing.
  await h.as(mod2);
  rows = await h.q(`select * from assigned_mods_list()`);
  h.eq('plain mod sees only their own row', rows.map((r) => r.user_id), [mod2]);
  h.eq('plain mod sees their head mod', rows[0].head_id, head1);
  await h.fails('plain mod cannot assign', `select assign_mod_head($1, $2)`, [mod3, head1]);
  await h.fails('plain mod cannot take themselves off', `select assign_mod_head($1, null)`, [mod2]);
  await h.as(member);
  await h.fails('member cannot list', `select * from assigned_mods_list()`);
  await h.fails('member cannot assign', `select assign_mod_head($1, $2)`, [mod3, head1]);
  await h.as(null);
  await h.fails('anon cannot assign', `select assign_mod_head($1, $2)`, [mod3, head1]);
}
