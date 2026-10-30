// 657: in the staff servers only a site admin gives out a role with Administrator or turns it on.
// The live guard needs later helpers (area roles, staff role ids), so they get stand-ins driven by a table.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '657_staff_admin_roles.sql'), 'utf8');

const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
create table public.t657 (k text primary key, id uuid, v boolean);
grant select on public.t657 to authenticated;
grant insert, delete on public.member_roles to authenticated;
grant update on public.roles to authenticated;
alter table public.member_roles disable row level security;
alter table public.roles disable row level security;
grant select on public.roles, public.member_roles to authenticated;
create or replace function public.is_site_admin() returns boolean language sql security definer as $$ select coalesce((select v from public.t657 where k = 'admin'), false) $$;
create or replace function public.is_staff_user(u uuid) returns boolean language sql security definer as $$ select exists (select 1 from public.t657 where k = 'staff:' || u::text) $$;
create or replace function public.area_role_id(a text) returns uuid language sql security definer as $$ select null::uuid $$;
create or replace function public.hq_head_mod_role_id() returns uuid language sql security definer as $$ select id from public.t657 where k = 'hqhead' $$;
create or replace function public.hq_management_role_id() returns uuid language sql security definer as $$ select id from public.t657 where k = 'hqmgmt' $$;
create or replace function public.modserver_management_role_id() returns uuid language sql security definer as $$ select id from public.t657 where k = 'modmgmt' $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`657 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('657 runs', () => h.db.exec(MIG));
  await h.ok('657 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`create trigger member_roles_staff_guard before insert or delete on public.member_roles for each row execute function public.staff_role_guard();
                   create trigger roles_staff_guard before delete or update on public.roles for each row execute function public.staff_role_guard();`);
  const owner = await h.signup('own657@x.test', 'own657');
  const mgr = await h.signup('mgr657@x.test', 'mgr657');
  const mod = await h.signup('mod657@x.test', 'mod657');
  const mk = async (name) => (await h.one(`insert into public.servers (name, owner_id) values ($1, $2) returning id`, [name, owner])).id;
  const staff = await mk('modserver657');
  const other = await mk('other657');
  for (const s of [staff, other]) await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4) on conflict do nothing`, [s, owner, mgr, mod]);
  const role = async (s, name, perms) => (await h.one(`insert into public.roles (server_id, name, perms) values ($1, $2, $3::jsonb) returning id`, [s, name, JSON.stringify(perms)])).id;
  const mgmt = await role(staff, 'Mgmt', {});
  const dot = await role(staff, 'dot', { administrator: true });
  const plain = await role(staff, 'Helpers', { send_messages: true });
  const otherAdmin = await role(other, 'Admin', { administrator: true });
  await h.db.query(`insert into public.t657 (k, id) values ('modmgmt', $1)`, [mgmt]);
  await h.db.query(`insert into public.t657 (k, v) values ('admin', false)`);

  const q = (sql, params) => () => h.db.query(sql, params);
  const give = `insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`;
  const take = `delete from public.member_roles where user_id = $1 and role_id = $2`;
  const count = async (u, r) => (await h.one(`select count(*)::int n from public.member_roles where user_id = $1 and role_id = $2`, [u, r])).n;

  // Giving.
  await h.as(mgr);
  await h.fails('manager gives an Administrator role in the staff server: refused', give, [staff, mod, dot]);
  await h.ok('a role without Administrator still goes', q(give, [staff, mod, plain]));
  await h.ok('outside the staff servers nothing changes', q(give, [other, mod, otherAdmin]));
  await h.admin();
  // Reaction roles: a security definer trigger gives the role while the reacting person is auth.uid().
  await h.db.exec(`create or replace function public.t657_give(s uuid, u uuid, r uuid) returns void language plpgsql security definer set search_path = public as $$
    begin perform set_config('yapper.bot', '1', true); insert into public.member_roles (server_id, user_id, role_id) values (s, u, r); end $$;
    grant execute on function public.t657_give(uuid, uuid, uuid) to authenticated;`);
  await h.as(mod);
  await h.fails('given through a security definer path (reaction roles): refused', `select public.t657_give($1, $2, $3)`, [staff, mod, dot]);

  // Editing roles.
  await h.as(mgr);
  await h.fails('turning Administrator on: refused', `update public.roles set perms = perms || '{"administrator": true}' where id = $1`, [plain]);
  await h.ok('moving or renaming a role that has it still works', q(`update public.roles set name = 'dot2', position = 3 where id = $1`, [dot]));
  await h.fails('turning Administrator off: refused', `update public.roles set perms = perms - 'administrator' where id = $1`, [dot]);
  await h.fails('changing what an Administrator role can do: refused', `update public.roles set perms = perms || '{"send_messages": true}' where id = $1`, [dot]);
  await h.fails('deleting an Administrator role: refused', `delete from public.roles where id = $1`, [dot]);

  await h.fails('moving a role to another server: refused', `update public.roles set server_id = $1 where id = $2`, [other, plain]);
  // Taking roles: the owner holds dot (an admin gave it), mod is Yapin' staff, plainUser isn't.
  await h.admin();
  const plainUser = await h.signup('pl657@x.test', 'pl657');
  await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2)`, [staff, plainUser]);
  await h.db.query(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3), ($1, $4, $5), ($1, $6, $5)`, [staff, owner, dot, plainUser, plain, mgr]);
  await h.db.query(`insert into public.t657 (k) values ('staff:' || $1)`, [mod]);
  await h.as(mgr);
  await h.fails('taking an Administrator role from someone else: refused', take, [owner, dot]);
  await h.fails('taking any role from Yapin staff: refused', take, [mod, plain]);
  await h.ok('taking a role from a member who is not staff still works', q(take, [plainUser, plain]));
  await h.ok('giving up your own role still works', q(take, [mgr, plain]));
  await h.admin();
  h.eq('staff member kept the role', await count(mod, plain), 1);
  h.eq('owner kept the Administrator role', await count(owner, dot), 1);
  h.eq('plain member lost theirs', await count(plainUser, plain), 0);
  await h.as(mgr);
  await h.fails('deleting a role Yapin staff hold: refused', `delete from public.roles where id = $1`, [plain]);
  await h.admin();
  const loose = await role(staff, 'Loose', {});
  await h.as(mgr);
  await h.ok('deleting a role no staff hold still works', q(`delete from public.roles where id = $1`, [loose]));
  await h.admin();

  // A site admin may do all of it.
  await h.db.query(`update public.t657 set v = true where k = 'admin'`);
  await h.as(mgr);
  await h.ok('a site admin may give it', q(give, [staff, mod, dot]));
  await h.ok('a site admin may take it', q(take, [mod, dot]));
  await h.ok('a site admin may take roles from staff', q(take, [mod, plain]));
  await h.ok('a site admin may change it', q(`update public.roles set perms = perms || '{"send_messages": true}' where id = $1`, [dot]));
  await h.admin();
  h.eq('removed', await count(mod, dot), 0);
}
