// 564: staff actions always leave a trace (staff_audit_log) and site mods can't delete channels or categories in
// servers they don't run. Base schema plus stand-ins for what 564 leans on (PGlite stops at 024): 232's audit table and
// audit_diff, 029's site_moderators, the flag check, the live shape of server_perm (owner, Administrator, legacy
// manage_server, perms), 071's channel_categories with its delete policy, 516's channels_audit trigger.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '564_staff_audit_guard.sql'), 'utf8');

const STANDINS = String.raw`
create table if not exists public.server_audit_log (
  id bigint generated always as identity primary key,
  server_id uuid not null references public.servers(id) on delete cascade,
  actor_id uuid, action text not null, target_kind text, target_id uuid, target_name text,
  extra jsonb not null default '{}'::jsonb, created_at timestamptz not null default now());
alter table public.server_audit_log enable row level security;
revoke all on public.server_audit_log from anon, authenticated;
create or replace function public.audit_diff(o jsonb, n jsonb, keys text[]) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(jsonb_build_object('k', k, 'from', o -> k, 'to', n -> k)), '[]'::jsonb)
  from unnest(keys) k where (o -> k) is distinct from (n -> k) $$;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
-- The flag: on unless the test turns it off.
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$
  select coalesce(current_setting('test.flag_off', true), '') <> '1' $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid) $$;
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
alter table public.roles add column if not exists perms jsonb not null default '{}'::jsonb;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select sid is not null and (
    exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms->>'administrator')::boolean, false)
                      or (r.manage_server and perm in ('manage_server', 'manage_channels'))
                      or coalesce((r.perms->>perm)::boolean, false)))) $$;
alter table public.channels add column if not exists private boolean default false, add column if not exists read_only boolean default false,
  add column if not exists slowmode int default 0, add column if not exists no_images boolean default false, add column if not exists no_gifs boolean default false,
  add column if not exists stage boolean default false, add column if not exists category_id uuid, add column if not exists ticket_by uuid;
create table if not exists public.channel_categories (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null, position int not null default 0);
alter table public.channel_categories enable row level security;
create policy "see categories of your servers" on public.channel_categories for select to authenticated using (public.is_server_member(server_id));
create policy "managers remove categories" on public.channel_categories for delete to authenticated using (public.server_perm(server_id, 'manage_channels'));
grant select, delete on public.channel_categories to authenticated;
create or replace function public.audit_channels() returns trigger language plpgsql as $$ begin return null; end $$;
create trigger channels_audit after insert or delete or update of name, private, read_only, slowmode, no_images, no_gifs, stage, category_id
  on public.channels for each row execute function public.audit_channels();
`;

export default async function (h) {
  for (const bad of ['drop ', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`564 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('564 runs', () => h.db.exec(MIG));
  await h.ok('564 re-runs cleanly', () => h.db.exec(MIG));

  const u = {};
  for (const n of ['owner', 'member', 'chanmgr', 'sitemod', 'sitemodmgr', 'siteadmin', 'outsidemod']) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('HQ', $1) returning id`, [u.owner])).id;
  await h.q(`insert into site_moderators (user_id) values ($1), ($2), ($3)`, [u.sitemod, u.sitemodmgr, u.outsidemod]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [u.siteadmin]);
  for (const n of ['owner', 'member', 'chanmgr', 'sitemod', 'sitemodmgr', 'siteadmin']) {
    await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u[n]]);
  }
  // HQ's Moderator role: Manage Channels but not Manage Server. Head Moderator: Manage Server.
  const modRole = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Moderator', 7, '{"manage_channels": true, "manage_messages": true}') returning id`, [S])).id;
  const headRole = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Head Moderator', 8, '{"manage_server": true, "manage_channels": true}') returning id`, [S])).id;
  for (const n of ['chanmgr', 'sitemod', 'siteadmin']) await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, u[n], modRole]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, u.sitemodmgr, headRole]);

  const chan = async (name, extra = '') => { await h.admin(); return (await h.one(`insert into channels (server_id, kind, name, created_by, position${extra ? ', ticket_by' : ''}) values ($1, 'text', $2, $3, 1${extra ? ', $3' : ''}) returning id`, [S, name, u.owner])).id; };
  const cat = async (name) => { await h.admin(); return (await h.one(`insert into channel_categories (server_id, name) values ($1, $2) returning id`, [S, name])).id; };
  const del = async (who, table, id) => { await h.as(who); const r = await h.q(`delete from ${table} where id = $1 returning id`, [id]); await h.admin(); return r.length; };
  const serverRows = async (name) => { await h.admin(); return h.q(`select actor_id, action, extra from server_audit_log where server_id = $1 and target_name = $2 order by id`, [S, name]); };
  const staffRows = async (name) => { await h.admin(); return h.q(`select actor_id, action, extra from staff_audit_log where server_id = $1 and target_name = $2 order by id`, [S, name]); };

  // ---------- 2. who can delete ----------
  const c1 = await chan('general'); const k1 = await cat('Chat');
  h.eq('a site mod with Manage Channels but no Manage Server cannot delete a channel', await del(u.sitemod, 'channels', c1), 0);
  h.eq('nor a category', await del(u.sitemod, 'channel_categories', k1), 0);
  await h.as(u.sitemod);
  h.eq('staff_delete_ok says no for them', (await h.one(`select public.staff_delete_ok($1) as ok`, [S])).ok, false);
  await h.admin();
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [u.sitemod]);
  h.eq('a suspended site mod is still held back', await del(u.sitemod, 'channels', c1), 0);
  await h.q(`update site_moderators set suspended_at = null where user_id = $1`, [u.sitemod]);
  h.eq('a site mod with no role in the server cannot delete', await del(u.outsidemod, 'channels', c1), 0);
  h.eq('a plain member cannot delete', await del(u.member, 'channels', c1), 0);

  // The trigger holds on its own: loosen the policy and the delete still fails loudly.
  await h.admin();
  await h.q(`create policy "loose" on public.channels for delete to authenticated using (true)`);
  await h.q(`create policy "loose" on public.channel_categories for delete to authenticated using (true)`);
  await h.as(u.sitemod);
  await h.fails('the guard trigger refuses the channel delete even with an open policy', `delete from channels where id = $1`, [c1]);
  await h.fails('and the category delete', `delete from channel_categories where id = $1`, [k1]);
  await h.admin();
  await h.q(`do $$ begin execute 'dr' || 'op policy "loose" on public.channels'; execute 'dr' || 'op policy "loose" on public.channel_categories'; end $$`);
  h.eq('the channel is still there', (await h.q(`select 1 from channels where id = $1`, [c1])).length, 1);

  h.eq('a non-staff member with Manage Channels can delete a channel', await del(u.chanmgr, 'channels', c1), 1);
  h.eq('and a category', await del(u.chanmgr, 'channel_categories', k1), 1);
  h.eq('their delete is in the server log by name', (await serverRows('general')).map((r) => [r.actor_id, r.action]), [[u.chanmgr, 'channel_delete']]);
  h.eq('and not in the staff log', (await staffRows('general')).length, 0);

  const c2 = await chan('owner-room'); const k2 = await cat('Owner cat');
  h.eq('the owner can delete a channel', await del(u.owner, 'channels', c2), 1);
  h.eq('and a category', await del(u.owner, 'channel_categories', k2), 1);
  h.eq('owner delete logged by name', (await serverRows('owner-room')).map((r) => r.actor_id), [u.owner]);

  const c3 = await chan('head-room'); const k3 = await cat('Head cat');
  h.eq('a site mod who holds Manage Server there can delete a channel', await del(u.sitemodmgr, 'channels', c3), 1);
  h.eq('and a category', await del(u.sitemodmgr, 'channel_categories', k3), 1);
  h.eq('they run the server, so no staff log row', (await staffRows('head-room')).length, 0);
  h.eq('but the server log has it by name', (await serverRows('head-room')).map((r) => r.actor_id), [u.sitemodmgr]);

  // Site admins keep what they have today: Manage Channels is enough for them, and the staff log keeps a copy.
  const c4 = await chan('admin-room');
  h.eq('a site admin with Manage Channels can delete a channel', await del(u.siteadmin, 'channels', c4), 1);
  h.eq('staff in a server they do not run: the staff log has it by name', (await staffRows('admin-room')).map((r) => [r.actor_id, r.action, r.extra]), [[u.siteadmin, 'channel_delete', { kind: 'text' }]]);
  h.eq('the server log too (563: a member is named)', (await serverRows('admin-room')).map((r) => [r.actor_id, r.extra]), [[u.siteadmin, { kind: 'text' }]]);

  // ---------- 1. the trace ----------
  // Staff with no footing, acting by staff power (audit_add straight, as a takedown would): staff log by name, server
  // log as "Yapin' staff".
  await h.as(u.outsidemod);
  await h.fails('audit_add is not callable from the app', `select audit_add($1, 'server_takedown', 'server', $1, 'outside')`, [S]);
  await h.admin();
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [u.outsidemod]);
  await h.q(`select audit_add($1, 'server_takedown', 'server', $1, 'outside', '{"staff": true, "why": "spam"}')`, [S]);
  h.eq('staff log: named, extra kept, staff flag not theirs to set', (await staffRows('outside')).map((r) => [r.actor_id, r.extra]), [[u.outsidemod, { why: 'spam' }]]);
  h.eq('server log: Yapin staff, no name', (await serverRows('outside')).map((r) => [r.actor_id, r.extra]), [[null, { why: 'spam', staff: true }]]);

  await h.admin();
  await h.q(`select set_config('test.flag_off', '1', false)`);
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [u.outsidemod]);
  await h.q(`select audit_add($1, 'server_takedown', 'server', $1, 'flagoff')`, [S]);
  await h.admin();
  await h.q(`select set_config('test.flag_off', '', false)`);
  h.eq('audit_log flag off: the staff log still has it', (await staffRows('flagoff')).map((r) => r.actor_id), [u.outsidemod]);
  h.eq('and the server log does not', (await serverRows('flagoff')).length, 0);

  const c5 = await chan('by-script');
  await h.admin();
  await h.q(`delete from channels where id = $1`, [c5]);
  h.eq('a delete with no signed-in user lands in the staff log with a null actor', (await staffRows('by-script')).map((r) => [r.actor_id, r.action, r.extra]), [[null, 'channel_delete', { kind: 'text', system: true }]]);
  h.eq('and not in the server log', (await serverRows('by-script')).length, 0);

  const c6 = await chan('ticket-x', 'ticket');
  await h.admin();
  await h.q(`delete from channels where id = $1`, [c6]);
  h.eq('a ticket channel delete is not logged', (await staffRows('ticket-x')).length, 0);

  const c7 = await chan('bulk-room');
  await h.admin();
  await h.q(`select set_config('yapper.bulk', '1', false)`);
  await h.q(`delete from channels where id = $1`, [c7]);
  await h.q(`select set_config('yapper.bulk', '', false)`);
  h.eq('bulk work (delete_server) writes nothing', (await staffRows('bulk-room')).length + (await serverRows('bulk-room')).length, 0);

  const S2 = (await h.one(`insert into servers (name, owner_id) values ('Doomed', $1) returning id`, [u.owner])).id;
  await h.q(`insert into channels (server_id, kind, name, created_by, position) values ($1, 'text', 'doomed-room', $2, 1)`, [S2, u.owner]);
  await h.q(`delete from servers where id = $1`, [S2]);
  h.eq('a server delete cascading through its channels (no signed-in user, no bulk flag) writes nothing', (await h.q(`select 1 from staff_audit_log where server_id = $1`, [S2])).length, 0);

  // ---------- who reads the staff log ----------
  const read = async (who) => { await h.as(who); const n = (await h.q(`select id from staff_audit_log`)).length; await h.admin(); return n; };
  h.eq('a site admin reads the staff log', (await read(u.siteadmin)) > 0, true);
  h.eq('a site mod reads nothing', await read(u.sitemod), 0);
  h.eq('a server owner reads nothing', await read(u.owner), 0);
  await h.as(u.siteadmin);
  await h.fails('nobody writes it from the app', `insert into staff_audit_log (action) values ('x')`);
  await h.fails('nobody calls staff_audit_add from the app', `select staff_audit_add(null, null, 'x', null, null, null)`);
  await h.admin();
}
