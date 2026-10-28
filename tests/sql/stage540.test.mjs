// 540: "Yapin' Management" roles in HQ and the Moderator Server, given and taken with Management (537's trigger).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const M537 = mig('537_management_role.sql');
const M540 = mig('540_management_roles.sql');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const HQ = '00000000-0000-4000-8000-00000000b002';
const MS = '00000000-0000-4000-8000-00000000b003';

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (M540.toLowerCase().includes(bad)) throw new Error(`540 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(`alter table public.roles add column if not exists perms jsonb not null default '{}';
    create or replace function public.hq_head_mod_role_id() returns uuid language sql immutable as $$ select '3650f1e2-7c4b-4d9a-8e21-5a6b7c8d9e01'::uuid $$;`);
  await h.q(`insert into feature_flags (key, label, mode) values ('head_mods', 'Head mods', 'everyone') on conflict (key) do nothing`);
  const admin = await h.signup('admin@test.dev', 'boss');
  const mgr = await h.signup('mgr@test.dev', 'manager');
  const outsider = await h.signup('out@test.dev', 'outsider');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Yapper Headquarters', $3), ($2, 'Moderator Server', $3)`, [HQ, MS, admin]);
  await h.q(`insert into roles (id, server_id, name, position, perms) values
    ('3650f1e2-7c4b-4d9a-8e21-5a6b7c8d9e01', $1, 'Head Moderator', 8, '{"ban_members": true}'),
    (gen_random_uuid(), $1, 'Moderator', 7, '{}'), (gen_random_uuid(), $1, 'Developer', 9, '{}'), (gen_random_uuid(), $1, 'Admin', 10, '{}'),
    (gen_random_uuid(), $2, 'Head Moderator', 3, '{"kick_members": true}'), (gen_random_uuid(), $2, 'Owner', 4, '{}'), (gen_random_uuid(), $2, 'Moderators', 1, '{}')`, [HQ, MS]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $3), ($2, $3), ($1, $4)`, [HQ, MS, mgr, outsider]);
  await h.ok('537 runs', () => h.db.exec(M537));
  await h.ok('540 runs', () => h.db.exec(M540));
  await h.ok('540 re-runs cleanly', () => h.db.exec(M540));
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'management'`, [admin]);

  const order = async (sid) => (await h.q(`select name from roles where server_id = $1 order by position desc`, [sid])).map((r) => r.name);
  h.eq('HQ: under Admin, above Developer', await order(HQ), ['Admin', 'Yapin\' Management', 'Developer', 'Head Moderator', 'Moderator']);
  h.eq('Mod Server: above Head Moderator', await order(MS), ['Owner', 'Yapin\' Management', 'Head Moderator', 'Moderators']);
  h.eq('one role each, made once', (await h.one(`select count(*)::int n from roles where name = 'Yapin'' Management'`)).n, 2);
  h.eq('HQ role has Head Moderator perms', (await h.one(`select perms from roles where id = hq_management_role_id()`)).perms, { ban_members: true });
  h.eq('Mod Server role has its Head Moderator perms', (await h.one(`select perms from roles where id = modserver_management_role_id()`)).perms, { kick_members: true });

  const held = async (uid) => (await h.q(`select r.name, r.server_id from member_roles mr join roles r on r.id = mr.role_id where mr.user_id = $1 and r.name = 'Yapin'' Management' order by r.server_id`, [uid])).length;
  await h.as(admin);
  await h.ok('admin gives Management', () => h.q(`select admin_set_manager($1, true)`, [mgr]));
  await h.admin();
  h.eq('manager gets both roles', await held(mgr), 2);
  h.eq('bot flag put back', (await h.one(`select coalesce(current_setting('yapper.bot', true), '') v`)).v, '');
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [mgr]);
  h.eq('paused: roles gone', await held(mgr), 0);
  await h.q(`update site_moderators set suspended_at = null where user_id = $1`, [mgr]);
  h.eq('unpaused: roles back', await held(mgr), 2);
  await h.as(admin);
  await h.ok('admin takes Management off', () => h.q(`select admin_set_manager($1, false)`, [mgr]));
  await h.admin();
  h.eq('removed: roles gone', await held(mgr), 0);
  h.eq('nobody else got it', await held(outsider), 0);

  // Only site admins touch the staff roles in the app, even as a server owner with every permission.
  await h.q(`update servers set owner_id = $1 where id = $2`, [outsider, MS]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [MS, outsider]);
  await h.as(outsider);
  h.eq('owner cannot rename the Management role', await h.q(`update roles set name = 'mine' where id = modserver_management_role_id()`).then(() => 'ok', (e) => e.message), "This role follows the Yapin' staff list. Ask an admin");
  h.eq('owner cannot hand it out', await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, modserver_management_role_id())`, [MS, outsider]).then(() => 'ok', (e) => e.message), "This role follows the Yapin' staff list. Ask an admin");
  h.eq('owner can still edit other roles', (await h.q(`update roles set color = '#123456' where server_id = $1 and name = 'Moderators' returning id`, [MS])).length, 1);
  await h.admin();
  h.eq('Management role untouched', (await h.one(`select name from roles where id = modserver_management_role_id()`)).name, "Yapin' Management");
  await h.as(admin);
  await h.ok('site admin gives Management again (trigger passes the guard)', () => h.q(`select admin_set_manager($1, true)`, [mgr]));
  await h.admin();
  h.eq('roles back', await held(mgr), 2);
  await h.ok('leaving a server still drops the role', () => h.q(`delete from server_members where server_id = $1 and user_id = $2`, [MS, mgr]));
  h.eq('one left', await held(mgr), 1);
}
