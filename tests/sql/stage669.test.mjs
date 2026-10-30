// 669: with is_staff_user locked down as it is live (postgres and service_role only), 657's guard made every role
// change in the staff servers fail with "permission denied for function is_staff_user". 669 asks a wrapper instead.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const read = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const M657 = read('657_staff_admin_roles.sql');
const MIG = read('669_staff_guard_permission.sql');

const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
create table public.t669 (k text primary key, id uuid, v boolean);
grant select on public.t669 to authenticated;
grant insert, delete on public.member_roles to authenticated;
grant update on public.roles to authenticated;
alter table public.member_roles disable row level security;
alter table public.roles disable row level security;
grant select on public.roles, public.member_roles to authenticated;
create or replace function public.is_site_admin() returns boolean language sql security definer as $$ select coalesce((select v from public.t669 where k = 'admin'), false) $$;
create or replace function public.is_staff_user(u uuid) returns boolean language sql security definer as $$ select exists (select 1 from public.t669 where k = 'staff:' || u::text) $$;
-- As live: nobody but the owner may call it.
revoke all on function public.is_staff_user(uuid) from public, anon, authenticated;
-- Like live: the owner of a server has every permission there; others only what t669 grants them in that server.
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql security definer as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
      or exists (select 1 from public.t669 where k = 'perm:' || perm || ':' || sid::text || ':' || auth.uid()::text) $$;
create or replace function public.area_role_id(a text) returns uuid language sql security definer as $$ select null::uuid $$;
create or replace function public.hq_head_mod_role_id() returns uuid language sql security definer as $$ select id from public.t669 where k = 'hqhead' $$;
create or replace function public.hq_management_role_id() returns uuid language sql security definer as $$ select id from public.t669 where k = 'hqmgmt' $$;
create or replace function public.modserver_management_role_id() returns uuid language sql security definer as $$ select id from public.t669 where k = 'modmgmt' $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`669 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(M657);
  await h.db.exec(`create trigger member_roles_staff_guard before insert or delete on public.member_roles for each row execute function public.staff_role_guard();
                   create trigger roles_staff_guard before delete or update on public.roles for each row execute function public.staff_role_guard();`);
  const owner = await h.signup('own669@x.test', 'own669');
  const mgr = await h.signup('mgr669@x.test', 'mgr669');
  const mod = await h.signup('mod669@x.test', 'mod669');
  const plainUser = await h.signup('pl669@x.test', 'pl669');
  const mk = async (name) => (await h.one(`insert into public.servers (name, owner_id) values ($1, $2) returning id`, [name, owner])).id;
  const staff = await mk('modserver669');
  const other = await mk('other669');
  for (const s of [staff, other]) await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4), ($1, $5) on conflict do nothing`, [s, owner, mgr, mod, plainUser]);
  const role = async (s, name, perms) => (await h.one(`insert into public.roles (server_id, name, perms) values ($1, $2, $3::jsonb) returning id`, [s, name, JSON.stringify(perms)])).id;
  const mgmt = await role(staff, 'Mgmt', {});
  const dot = await role(staff, 'dot', { administrator: true });
  const plain = await role(staff, 'Helpers', { send_messages: true });
  const otherPlain = await role(other, 'Helpers', {});
  await h.db.query(`insert into public.t669 (k, id) values ('modmgmt', $1)`, [mgmt]);
  await h.db.query(`insert into public.t669 (k, v) values ('admin', false)`);
  await h.db.query(`insert into public.t669 (k) values ('staff:' || $1), ('perm:manage_roles:' || $3 || ':' || $2)`, [mod, mgr, staff]);

  const q = (sql, params) => () => h.db.query(sql, params);
  const give = `insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`;
  const take = `delete from public.member_roles where user_id = $1 and role_id = $2`;
  const count = async (u, r) => (await h.one(`select count(*)::int n from public.member_roles where user_id = $1 and role_id = $2`, [u, r])).n;

  // The bug, with 657 alone: even giving a plain role in the staff server fails on is_staff_user.
  await h.as(mgr);
  let msg = '';
  try { await h.db.query(give, [staff, plainUser, plain]); } catch (e) { msg = e.message; }
  h.eq('657 alone: giving a plain role in a staff server hits is_staff_user', /permission denied for function is_staff_user/.test(msg), true);
  await h.ok('657 alone: other servers were fine', q(give, [other, plainUser, otherPlain]));

  await h.admin();
  await h.ok('669 runs', () => h.db.exec(MIG));
  await h.ok('669 re-runs cleanly', () => h.db.exec(MIG));

  // Giving and taking in the staff server work again.
  await h.as(mgr);
  await h.ok('giving a plain role in the staff server works', q(give, [staff, plainUser, plain]));
  await h.ok('taking it from a member who is not staff works', q(take, [plainUser, plain]));
  await h.ok('giving a plain role to staff works', q(give, [staff, mod, plain]));
  await h.fails('giving an Administrator role is still refused', give, [staff, mod, dot]);
  // 657's protections still hold.
  await h.fails('taking a role from Yapin staff is still refused', take, [mod, plain]);
  await h.fails('deleting a role Yapin staff hold is still refused', `delete from public.roles where id = $1`, [plain]);
  await h.admin();
  h.eq('staff member kept the role', await count(mod, plain), 1);
  const loose = await role(staff, 'Loose', {});
  await h.as(mgr);
  await h.ok('deleting a role no staff hold works', q(`delete from public.roles where id = $1`, [loose]));

  // The wrapper can't be used to look up who is staff.
  h.eq('a manager of the server gets the answer', (await h.one(`select public.role_guard_is_staff($1, $2) v`, [staff, mod])).v, true);
  h.eq('asking about a staff server from another server gets false', (await h.one(`select public.role_guard_is_staff($1, $2) v`, [other, mod])).v, false);
  // Anyone can make a server and own it: that must not open the staff list.
  await h.admin();
  const mine = (await h.one(`insert into public.servers (name, owner_id) values ('mine669', $1) returning id`, [plainUser])).id;
  await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [mine, plainUser, mod]);
  await h.as(plainUser);
  h.eq('owner of some other server (staff member in it) gets false', (await h.one(`select public.role_guard_is_staff($1, $2) v`, [mine, mod])).v, false);
  h.eq('someone without Manage Roles there gets false', (await h.one(`select public.role_guard_is_staff($1, $2) v`, [staff, mod])).v, false);
  await h.as(null);
  await h.fails('logged out: not callable', `select public.role_guard_is_staff($1, $2)`, [staff, mod]);
  await h.admin();
}
