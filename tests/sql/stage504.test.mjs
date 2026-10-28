// 504: a non-owner can only give a role whose permissions they have (Administrator only with Administrator).
// Starts from stage 24 with stand-ins for the live pieces role_guard leans on (role perms columns, server_perm with
// role perms, my_top_role_position, is_site_admin, can_edit_role, reaction roles and server bots) and the member_roles
// / roles triggers, then 504 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '504_role_give_perms.sql'), 'utf8');

const STANDINS = `
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists manage_server boolean not null default false;
alter table public.roles add column if not exists manage_messages boolean not null default false;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)
                      or (r.manage_messages and perm = 'manage_messages')));
$$;
create or replace function public.my_top_role_position(sid uuid) returns integer language sql stable security definer set search_path = public as $$
  select coalesce(max(r.position), -1) from public.member_roles mr join public.roles r on r.id = mr.role_id
  where mr.server_id = sid and mr.user_id = auth.uid();
$$;
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select false $$;
create or replace function public.can_edit_role(rid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.server_plus_on(sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.reaction_emoji_ok(e text) returns boolean language sql immutable as $$ select e <> '' $$;
create table if not exists public.reaction_roles (message_id uuid, emoji text, role_id uuid, server_id uuid, primary key (message_id, emoji));
create or replace function public.clear_reaction_roles(mid uuid) returns void language sql as $$ delete from public.reaction_roles where message_id = mid $$;
create table if not exists public.server_bots (server_id uuid, bot text, enabled boolean default true, config jsonb, primary key (server_id, bot));
grant select, insert, update, delete on public.reaction_roles, public.server_bots to authenticated;
alter policy "managers assign roles" on public.member_roles with check (public.server_perm(server_id, 'manage_roles'));
alter policy "managers unassign roles" on public.member_roles using (public.server_perm(server_id, 'manage_roles'));
`;
const TRIGGERS = `
create or replace trigger member_roles_guard before insert or delete on public.member_roles for each row execute function public.role_guard();
create or replace trigger roles_sync_legacy before insert or update on public.roles for each row execute function public.roles_sync_legacy();
create or replace trigger roles_guard before insert or update or delete on public.roles for each row execute function public.role_guard();
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`504 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  const owner = await h.signup('o@x.com', 'owner');
  const admin = await h.signup('a@x.com', 'coadmin');
  const rolesMgr = await h.signup('m@x.com', 'rolesmanager');
  const msgMgr = await h.signup('mm@x.com', 'msgmanager');
  const alt = await h.signup('alt@x.com', 'alt');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  for (const u of [owner, admin, rolesMgr, msgMgr, alt]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  const role = async (name, pos, perms = '{}', ms = false, mm = false) => (await h.one(
    `insert into roles (server_id, name, position, perms, manage_server, manage_messages) values ($1, $2, $3, $4::jsonb, $5, $6) returning id`,
    [S, name, pos, perms, ms, mm])).id;
  const ownerRole = await role('OWNER', 60, '{"administrator": true}');
  const coAdmin = await role('Co-admin', 58, '{"administrator": true}');
  const mgrRole = await role('Roles manager', 50, '{"manage_roles": true, "timeout_members": true}');
  const lowAdmin = await role('Low admin', 40, '{"administrator": true}');
  const kicker = await role('Kicker', 35, '{"kick_members": true}');
  const timeouter = await role('Timeouter', 34, '{"timeout_members": true}');
  const legacyServer = await role('Legacy server', 33, '{}', true, false);
  const legacyMsgs = await role('Legacy messages', 32, '{}', false, true);
  const msgMgrRole = await role('Message manager', 49, '{"manage_roles": true}', false, true);
  const plain = await role('Member', 10);
  const give = (uid, rid) => h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, uid, rid]);
  await give(admin, coAdmin);
  await give(rolesMgr, mgrRole);
  await give(msgMgr, msgMgrRole);
  await give(alt, plain);

  await h.ok('504 runs', () => h.db.exec(MIG));
  await h.db.exec(TRIGGERS);
  await h.ok('504 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag role_give_confirm in test', (await h.one(`select mode from feature_flags where key = 'role_give_confirm'`))?.mode, 'test');

  const has = async (uid, rid) => { await h.admin(); return !!(await h.one(`select 1 x from member_roles where user_id = $1 and role_id = $2`, [uid, rid])); };
  const tryGive = async (by, uid, rid) => { await h.as(by); return h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, uid, rid]); };
  const take = async (by, uid, rid) => { await h.as(by); return h.q(`delete from member_roles where server_id = $1 and user_id = $2 and role_id = $3`, [S, uid, rid]); };

  // The owner can still give any role, the top one included (what happened in the report).
  await h.ok('owner gives OWNER', () => tryGive(owner, alt, ownerRole));
  h.eq('alt has OWNER', await has(alt, ownerRole), true);
  await h.ok('owner takes it back', () => take(owner, alt, ownerRole));
  h.eq('alt no longer has OWNER', await has(alt, ownerRole), false);

  // Someone with Manage Roles only: Administrator roles below them are refused now, plain and own-perm roles still go.
  await h.as(rolesMgr);
  await h.fails('roles manager cannot give an Administrator role below them', `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, lowAdmin]);
  h.eq('alt did not get Low admin', await has(alt, lowAdmin), false);
  await h.as(rolesMgr);
  await h.fails('roles manager cannot give a perm they lack (kick_members)', `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, kicker]);
  await h.as(rolesMgr);
  await h.fails('roles manager cannot give legacy Manage Server', `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, legacyServer]);
  await h.as(rolesMgr);
  await h.fails('roles manager cannot give legacy Manage Messages', `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, legacyMsgs]);
  await h.ok('roles manager gives a perm they have (timeout_members)', () => tryGive(rolesMgr, alt, timeouter));
  await h.ok('roles manager gives a plain role', () => tryGive(rolesMgr, owner, plain));
  h.eq('timeouter given', await has(alt, timeouter), true);
  // Still can't reach at or above their own top role (unchanged).
  await h.as(rolesMgr);
  await h.fails('roles manager cannot give their own top role', `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, mgrRole]);
  // Taking roles away is unchanged: below your top, whatever perms the role has.
  await h.admin();
  await give(alt, lowAdmin);
  await h.ok('roles manager can still take an Administrator role below them', () => take(rolesMgr, alt, lowAdmin));
  h.eq('Low admin taken', await has(alt, lowAdmin), false);

  // Legacy Manage Messages holder can hand out a Manage Messages role below them.
  await h.ok('message manager gives legacy Manage Messages', () => tryGive(msgMgr, alt, legacyMsgs));

  // A non-owner with Administrator keeps handing out Administrator roles below them (175 such grants in 30 days live).
  await h.ok('co-admin gives an Administrator role below them', () => tryGive(admin, alt, lowAdmin));
  h.eq('alt has Low admin from the co-admin', await has(alt, lowAdmin), true);
  await h.as(admin);
  await h.fails('co-admin still cannot give a role at or above their top', `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, ownerRole]);

  // The app's own grants (reaction roles, Plus roles) set yapper.bot and skip the check, as before.
  await h.as(rolesMgr);
  await h.ok('yapper.bot grant still goes through', async () => {
    await h.db.exec(`begin; select set_config('yapper.bot', '1', true);`);
    await h.db.query(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, kicker]);
    await h.db.exec(`commit;`);
  });
  h.eq('kicker given by the app', await has(alt, kicker), true);

  // Permission values must be true/false: "yes" read as true and slipped past the "permission you don't have" loops.
  await h.as(owner);
  await h.fails('even the owner cannot store a non-boolean permission', `insert into roles (server_id, name, position, perms) values ($1, 'x', 5, '{"kick_members": "yes"}')`, [S]);
  await h.admin();
  await h.fails('nor can the service role', `update roles set perms = '{"ban_members": 1}' where id = $1`, [plain]);
  // A role stored with a string value before 504 still counts as giving that power.
  await h.q(`alter table roles disable trigger roles_sync_legacy`);
  const legacyStr = await role('Old string', 31, '{"ban_members": "t"}');
  await h.q(`alter table roles enable trigger roles_sync_legacy`);
  await h.as(rolesMgr);
  await h.fails('roles manager cannot give a role with {"ban_members":"t"}', `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, alt, legacyStr]);
  await h.ok('true/false permissions still save', async () => { await h.as(owner); await h.q(`insert into roles (server_id, name, position, perms) values ($1, 'fine', 5, '{"timeout_members": true, "kick_members": false}')`, [S]); });

  // Reaction roles: linking a role to an emoji follows the same rule (the reaction hands it out as the app).
  await h.admin();
  const chan = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'roles', $1, $2) returning id`, [S, owner])).id;
  const msg = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'pick') returning id`, [chan, owner])).id;
  const rr = async (by, rid) => { await h.as(by); return h.q(`select set_reaction_roles($1, $2::jsonb)`, [msg, JSON.stringify([{ emoji: '⭐', role_id: rid }])]); };
  await h.as(rolesMgr);
  await h.fails('roles manager cannot make Low admin a reaction role', `select set_reaction_roles($1, $2::jsonb)`, [msg, JSON.stringify([{ emoji: '⭐', role_id: lowAdmin }])]);
  await h.as(rolesMgr);
  await h.fails('roles manager cannot make Kicker a reaction role', `select set_reaction_roles($1, $2::jsonb)`, [msg, JSON.stringify([{ emoji: '⭐', role_id: kicker }])]);
  await h.ok('roles manager can make Timeouter a reaction role', () => rr(rolesMgr, timeouter));
  await h.ok('co-admin can make Low admin a reaction role', () => rr(admin, lowAdmin));
  await h.ok('owner can make OWNER a reaction role', () => rr(owner, ownerRole));
  await h.admin();
  h.eq('reaction role saved', (await h.one(`select role_id from reaction_roles where message_id = $1`, [msg])).role_id, ownerRole);

  // Levels rewards: same rule for reward roles (Administrator rewards were already owner only).
  await h.admin();
  const srvMgr = await h.signup('s@x.com', 'servermanager');
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [S, srvMgr]);
  const srvRole = await role('Server manager', 45, '{"manage_server": true, "manage_roles": true}');
  await give(srvMgr, srvRole);
  const lv = (rid) => JSON.stringify({ rewards: [{ level: 5, role_id: rid }] });
  await h.as(srvMgr);
  await h.fails('server manager cannot reward Kicker', `select set_server_bot($1, 'levels', true, $2::jsonb)`, [S, lv(kicker)]);
  await h.as(srvMgr);
  await h.fails('server manager still cannot reward an Administrator role', `select set_server_bot($1, 'levels', true, $2::jsonb)`, [S, lv(lowAdmin)]);
  await h.ok('server manager can reward a plain role', async () => { await h.as(srvMgr); await h.q(`select set_server_bot($1, 'levels', true, $2::jsonb)`, [S, lv(plain)]); });
  await h.ok('owner can reward Kicker', async () => { await h.as(owner); await h.q(`select set_server_bot($1, 'levels', true, $2::jsonb)`, [S, lv(kicker)]); });

  // The helper is not callable by anon.
  await h.admin();
  h.eq('anon cannot run can_give_role_perms', (await h.one(`select has_function_privilege('anon', 'public.can_give_role_perms(uuid, uuid)', 'execute') x`)).x, false);

  // Role editing rules are untouched: a co-admin still can't make a new Administrator role.
  await h.as(admin);
  await h.fails('co-admin still cannot create an Administrator role', `insert into roles (server_id, name, position, perms) values ($1, 'x', 5, '{"administrator": true}')`, [S]);
  await h.admin();
}
