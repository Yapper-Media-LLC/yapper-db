// 636: kick_member / ban_member / server_timeout refuse the owner (and yourself) with a clear message, before the
// hierarchy check; the hierarchy check still refuses an equal or higher top role; the owner may act on an admin; a
// higher role may act on a lower one. Runs on stage 24 plus stand-ins for the later bits (server_timeouts is 030,
// server_perm / outranks / is_staff_user are the live 134 shapes, applied by hand and not in the repo in full).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
alter table public.roles add column if not exists perms jsonb not null default '{}'::jsonb;
create table if not exists public.server_timeouts (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  until timestamptz not null, reason text not null default '', set_by uuid, created_at timestamptz not null default now(),
  primary key (server_id, user_id));
create table if not exists public.bot_accounts (bot text primary key, user_id uuid);
create table if not exists public.server_bots (server_id uuid, bot text, enabled boolean default true, primary key (server_id, bot));
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable as $$ select false $$;
-- Owner, or any role of mine that grants the permission.
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid() and coalesce((r.perms->>perm)::boolean, false)) $$;
-- The live outranks(): owner, or a higher top role than the target (never over the owner).
create or replace function public.outranks(sid uuid, target uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or (
      not exists (select 1 from public.servers where id = sid and owner_id = target)
      and coalesce((select max(r.position) from public.member_roles mr join public.roles r on r.id = mr.role_id where mr.server_id = sid and mr.user_id = auth.uid()), -1)
        > coalesce((select max(r.position) from public.member_roles mr join public.roles r on r.id = mr.role_id where mr.server_id = sid and mr.user_id = target), -1)
    ) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '636_owner_kick_guard.sql'), 'utf8');
  await h.ok('migration runs', () => h.db.exec(sql));
  await h.ok('migration runs twice', () => h.db.exec(sql));

  const owner = await h.signup('o@x.com', 'owner');
  const admin = await h.signup('a@x.com', 'admin'); // top role at 10, all three permissions
  const admin2 = await h.signup('a2@x.com', 'admin2'); // same role as admin
  const mod = await h.signup('m@x.com', 'mod'); // top role at 5
  const pleb = await h.signup('p@x.com', 'pleb'); // no roles
  await h.admin();
  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  for (const u of [owner, admin, admin2, mod, pleb]) await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u]);
  const perms = '{"kick_members": true, "ban_members": true, "timeout_members": true}';
  const adminRole = (await h.one(`insert into public.roles (server_id, name, position, perms) values ($1, 'Admin', 10, $2::jsonb) returning id`, [sid, perms])).id;
  const modRole = (await h.one(`insert into public.roles (server_id, name, position, perms) values ($1, 'Mod', 5, $2::jsonb) returning id`, [sid, perms])).id;
  for (const u of [admin, admin2]) await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, u, adminRole]);
  await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, mod, modRole]);

  // The error text a call fails with ('' when it succeeds).
  const errorOf = async (sql, params) => { try { await h.db.query(sql, params); return ''; } catch (e) { return e.message; } };
  const kick = (t) => errorOf(`select public.kick_member($1, $2)`, [sid, t]);
  const ban = (t) => errorOf(`select public.ban_member($1, $2)`, [sid, t]);
  const timeout = (t) => errorOf(`select public.server_timeout($1, $2, 60, 'test')`, [sid, t]);

  // 1. An admin on the owner: refused, and the message names the owner (not the role hierarchy).
  await h.as(admin);
  h.eq('admin kicking the owner', await kick(owner), "You can't kick the owner");
  h.eq('admin banning the owner', await ban(owner), "You can't ban the owner");
  h.eq('admin timing out the owner', await timeout(owner), "You can't time out the owner");
  // ...and on themselves.
  h.eq('admin kicking themselves', await kick(admin), "You can't kick yourself");
  h.eq('admin banning themselves', await ban(admin), "You can't ban yourself");
  h.eq('admin timing out themselves', await timeout(admin), 'Not yourself');
  // 2. An equal top role: the hierarchy refuses.
  h.eq('admin kicking an equal admin', await kick(admin2), "You can't kick someone with a role as high as yours");
  h.eq('admin banning an equal admin', await ban(admin2), "You can't ban someone with a role as high as yours");
  h.eq('admin timing out an equal admin', await timeout(admin2), "You can't time out someone with a role as high as yours");
  // 3. A mod (lower role) on the admin: the hierarchy refuses; the owner is still refused by name.
  await h.as(mod);
  h.eq('mod kicking an admin', await kick(admin), "You can't kick someone with a role as high as yours");
  h.eq('mod timing out the owner', await timeout(owner), "You can't time out the owner");
  // 4. Someone with the permission but no role can't touch a role-less member either (equal rank: -1 vs -1)...
  //    and a mod can act on a role-less member.
  h.eq('mod timing out a role-less member', await timeout(pleb), '');
  await h.admin();
  h.eq('timeout stored', (await h.one(`select count(*)::int as n from public.server_timeouts where server_id = $1 and user_id = $2`, [sid, pleb])).n, 1);
  await h.as(mod);
  h.eq('mod lifting it', await errorOf(`select public.server_timeout($1, $2, 0)`, [sid, pleb]), '');
  await h.admin();
  h.eq('timeout gone', (await h.one(`select count(*)::int as n from public.server_timeouts where server_id = $1 and user_id = $2`, [sid, pleb])).n, 0);
  // 5. Nobody without the permission at all, and nobody signed out (revoked from anon).
  await h.as(pleb);
  h.eq('no permission: kick', await kick(mod), "You can't kick people here");
  await h.as(null);
  await h.fails('anon: kick', `select public.kick_member($1, $2)`, [sid, mod]);
  await h.fails('anon: ban', `select public.ban_member($1, $2)`, [sid, mod]);
  await h.fails('anon: timeout', `select public.server_timeout($1, $2, 60)`, [sid, mod]);
  // 6. The owner outranks everyone: may kick, time out and ban an admin, but not themselves.
  await h.as(owner);
  h.eq('owner on themselves', await kick(owner), "You can't kick yourself");
  h.eq('owner timing out an admin', await timeout(admin2), '');
  h.eq('owner kicking an admin', await kick(admin), '');
  h.eq('owner banning an admin', await ban(admin2), '');
  await h.admin();
  h.eq('admin kicked', (await h.one(`select count(*)::int as n from public.server_members where server_id = $1 and user_id = $2`, [sid, admin])).n, 0);
  h.eq('admin2 banned', (await h.one(`select count(*)::int as n from public.server_bans where server_id = $1 and user_id = $2`, [sid, admin2])).n, 1);
  h.eq('admin2 removed', (await h.one(`select count(*)::int as n from public.server_members where server_id = $1 and user_id = $2`, [sid, admin2])).n, 0);
}
