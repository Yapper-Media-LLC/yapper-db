// 563: staff actions in a server always reach its audit log. Base schema plus 232's table and stand-ins for the
// helpers audit_add leans on (feature flag on, staff list, roles). Calls audit_add directly as different people.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;

const STANDINS = `
create table if not exists public.server_audit_log (
  id bigint generated always as identity primary key,
  server_id uuid not null references public.servers(id) on delete cascade,
  actor_id uuid, action text not null, target_kind text, target_id uuid, target_name text,
  extra jsonb not null default '{}'::jsonb, created_at timestamptz not null default now());
create table if not exists public.site_moderators (user_id uuid primary key);
create table if not exists public.site_admins (user_id uuid primary key);
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('563_audit_staff.sql');
  await h.ok('563 runs', () => h.db.exec(MIG));
  await h.ok('563 re-runs cleanly', () => h.db.exec(MIG));

  const u = {};
  for (const n of ['owner', 'member', 'modrole', 'staffer', 'staffowner', 'staffmember']) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Hub', $1) returning id`, [u.owner])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('Staff own', $1) returning id`, [u.staffowner])).id;
  await h.q(`insert into site_moderators values ($1), ($2), ($3), ($4)`, [u.modrole, u.staffer, u.staffowner, u.staffmember]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, u.staffmember]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, u.modrole]);
  const rid = (await h.one(`insert into roles (server_id, name) values ($1, 'Mod') returning id`, [sid])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, u.modrole, rid]);
  const rows = async (who) => { await h.admin(); return h.q(`select actor_id, action, extra from server_audit_log where server_id = $1 and target_name = $2 order by id`, [sid, who]); };

  await h.as(u.member);
  await h.q(`select audit_add($1, 'channel_delete', 'channel', gen_random_uuid(), 'member')`, [sid]);
  h.eq('a plain member is logged by name', (await rows('member')).map((r) => r.actor_id), [u.member]);

  await h.as(u.modrole);
  await h.q(`select audit_add($1, 'channel_delete', 'channel', gen_random_uuid(), 'modrole')`, [sid]);
  const m = await rows('modrole');
  h.eq('staff with a role in the server is logged by name', [m.length, m[0].actor_id, m[0].extra.staff ?? null], [1, u.modrole, null]);

  await h.as(u.staffer);
  await h.q(`select audit_add($1, 'channel_delete', 'channel', gen_random_uuid(), 'staffer', '{"kind":"text"}')`, [sid]);
  const s = await rows('staffer');
  h.eq('staff with no footing is logged as staff, keeping extra', [s.length, s[0].actor_id, s[0].extra], [1, null, { kind: 'text', staff: true }]);

  await h.as(u.staffmember);
  await h.q(`select audit_add($1, 'invite_create', 'invite', gen_random_uuid(), 'staffmember', '{"staff": true}')`, [sid]);
  const sm = await rows('staffmember');
  h.eq('staff who joined the server is logged by name, and extra.staff is not theirs to set', [sm[0].actor_id, sm[0].extra], [u.staffmember, {}]);

  await h.as(u.staffowner);
  await h.q(`select audit_add($1, 'channel_delete', 'channel', gen_random_uuid(), 'staffowner')`, [other]);
  await h.admin();
  const o = await h.q(`select actor_id from server_audit_log where server_id = $1`, [other]);
  h.eq('a staffer owning the server is logged by name', o.map((r) => r.actor_id), [u.staffowner]);

  await h.q(`select audit_add($1, 'channel_delete', 'channel', gen_random_uuid(), 'system')`, [sid]);
  h.eq('no signed-in user: nothing logged', (await rows('system')).length, 0);
  await h.as(u.member);
  await h.q(`select set_config('yapper.bulk', '1', false)`);
  await h.q(`select audit_add($1, 'channel_delete', 'channel', gen_random_uuid(), 'bulk')`, [sid]);
  await h.q(`select set_config('yapper.bulk', '', false)`);
  h.eq('bulk work: nothing logged', (await rows('bulk')).length, 0);
}
