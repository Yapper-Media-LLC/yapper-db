// 365 head mods: is_head_mod, admin_set_head_mod, badge + HQ role sync, head mods managing regular mods, stats, log access.
// PGlite stops at 24, so this adds stand-ins for what the migration touches (live versions are bigger).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '365_head_mods.sql'), 'utf8');
const HQ = '00000000-0000-4000-8000-00000000b002';
const ROLE = '3650f1e2-7c4b-4d9a-8e21-5a6b7c8d9e01';

const STANDINS = `
alter table public.profiles add column if not exists badges text[];
alter table public.profiles add column if not exists shown_badge text;
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.member_roles add column if not exists manual boolean not null default false;
create table if not exists public.site_moderators (user_id uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid, created_at timestamptz not null default now(), suspended_at timestamptz, suspended_reason text);
alter table public.site_moderators enable row level security;
create table if not exists public.site_community_managers (user_id uuid primary key);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
alter table public.mod_log enable row level security;
create policy "admins read the mod log" on public.mod_log for select to authenticated using (public.is_site_admin() or actor = auth.uid());
create policy "staff see moderators" on public.site_moderators for select to authenticated using (public.is_site_admin() or user_id = auth.uid());
grant select on public.mod_log, public.site_moderators to authenticated;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.feature_flags f where f.key = k and (f.mode = 'everyone' or (f.mode = 'test' and (auth.uid() = any(f.users) or sid = any(f.servers))))) $$;
create or replace function public.staff_mfa_ok() returns boolean language sql stable as $$ select true $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const antic = await h.signup('antic365@test.dev', 'antic365');
  const head = await h.signup('head365@test.dev', 'head365');
  const head2 = await h.signup('head2365@test.dev', 'head2365');
  const mod = await h.signup('mod365@test.dev', 'mod365');
  const newbie = await h.signup('new365@test.dev', 'new365');
  const rando = await h.signup('rando365@test.dev', 'rando365');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  // A small HQ: Moderator at 4, Developer 5, Admin 6.
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'HQ', $2)`, [HQ, antic]);
  await h.q(`insert into roles (server_id, name, position, perms) values ($1, 'Moderator', 4, '{"ban_members": true}'), ($1, 'Developer', 5, '{}'), ($1, 'Admin', 6, '{}')`, [HQ]);
  for (const u of [antic, head, head2, mod, newbie]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [HQ, u]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2), ($3)`, [head, head2, mod]);

  await h.db.exec(MIG);
  await h.ok('365 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('one Head Moderator role, just above Moderator', (await h.one(`select count(*)::int n, max(position) p, max(perms::text) perms from roles where server_id = $1 and name = 'Head Moderator'`, [HQ])),
    { n: 1, p: 5, perms: '{"ban_members": true}' });
  h.eq('Developer and Admin moved up once', (await h.one(`select string_agg(name || position, ',' order by position) s from roles where server_id = $1`, [HQ])).s,
    'Moderator4,Head Moderator5,Developer6,Admin7');
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'head_mods'`)).mode, 'test');
  // Flag on for the testers (test mode lists them).
  await h.q(`update feature_flags set users = array[$1, $2, $3]::uuid[] where key = 'head_mods'`, [antic, head, head2]);

  // ---- only admins make head mods ----
  await h.as(head);
  await h.fails('a mod cannot make a head mod', `select admin_set_head_mod($1, true)`, [head]);
  await h.as(antic);
  await h.fails('must be a moderator first', `select admin_set_head_mod($1, true)`, [rando]);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'head_mods'`);
  await h.as(antic);
  await h.fails('flag off: no new head mods', `select admin_set_head_mod($1, true)`, [head]);
  await h.admin();
  await h.q(`update feature_flags set mode = 'test' where key = 'head_mods'`);
  await h.as(antic);
  await h.q(`select admin_set_head_mod($1, true, 'leads US hours')`, [head]);
  await h.q(`select admin_set_head_mod($1, true)`, [head2]);
  await h.q(`select admin_set_head_mod($1, true)`, [head2]); // twice: no second log row
  await h.admin();
  h.eq('badge added first, mod badge kept', (await h.one(`select badges from profiles where id = $1`, [head])).badges, ['head_mod', 'mod']);
  h.eq('HQ role given', (await h.one(`select count(*)::int n from member_roles where user_id = $1 and role_id = $2`, [head, ROLE])).n, 1);
  h.eq('one log row per change', (await h.one(`select count(*)::int n from mod_log where action = 'head_mod_added'`)).n, 2);

  // ---- is_head_mod ----
  await h.as(head);
  h.eq('head mod is head', (await h.one(`select is_head_mod() v`)).v, true);
  await h.as(mod);
  h.eq('regular mod is not', (await h.one(`select is_head_mod() v`)).v, false);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'head_mods'`);
  await h.as(head);
  h.eq('flag off: nobody is head', (await h.one(`select is_head_mod() v`)).v, false);
  await h.fails('flag off: head mod cannot add mods', `select admin_set_moderator($1, true)`, [newbie]);
  await h.admin();
  await h.q(`update feature_flags set mode = 'test' where key = 'head_mods'`);

  // ---- head mods see the log and the mod list, regular mods don't ----
  await h.admin();
  await h.q(`insert into mod_log (actor, action, target_id) values ($1, 'ban', $2), ($1, 'delete', $2), ($1, 'warn', $2)`, [mod, rando]);
  await h.as(head);
  h.eq('head mod reads the whole log', (await h.one(`select count(*)::int n from mod_log`)).n, 5);
  h.eq('head mod sees every moderator', (await h.one(`select count(*)::int n from site_moderators`)).n, 3);
  await h.as(mod);
  h.eq('a mod still reads only their own rows', (await h.one(`select count(*)::int n from mod_log`)).n, 3);
  h.eq('a mod sees only themselves', (await h.one(`select count(*)::int n from site_moderators`)).n, 1);

  // ---- stats ----
  await h.as(mod);
  await h.fails('a mod cannot read stats', `select * from staff_mod_stats(7)`);
  await h.as(head);
  const st = await h.one(`select total::int, bans::int, deletes::int, warns::int, last_action is not null as seen from staff_mod_stats(7) where user_id = $1`, [mod]);
  h.eq('stats count a mod\'s actions', st, { total: 3, bans: 1, deletes: 1, warns: 1, seen: true });
  h.eq('a mod with no actions has 0', (await h.one(`select total::int t from staff_mod_stats(7) where user_id = $1`, [head2])).t, 0);

  // ---- head mods manage regular mods ----
  await h.as(head);
  await h.q(`select admin_set_moderator($1, true, 'from applications')`, [newbie]);
  await h.admin();
  h.eq('head mod added a mod (badge follows)', (await h.one(`select 'mod' = any(badges) v from profiles where id = $1`, [newbie])).v, true);
  await h.as(head);
  await h.q(`select admin_suspend_moderator($1, 'inactive')`, [newbie]);
  await h.q(`select admin_set_moderator($1, true)`, [newbie]); // reinstate
  await h.q(`select admin_set_moderator($1, false)`, [newbie]);
  await h.admin();
  h.eq('removed mod lost the badge', (await h.one(`select coalesce('mod' = any(badges), false) v from profiles where id = $1`, [newbie])).v, false);
  await h.as(head);
  await h.fails('head mod cannot touch another head mod', `select admin_suspend_moderator($1, 'x')`, [head2]);
  await h.fails('...or remove one', `select admin_set_moderator($1, false)`, [head2]);
  await h.fails('...or themselves', `select admin_set_moderator($1, false)`, [head]);
  await h.fails('...or an admin', `select admin_set_moderator($1, true)`, [antic]);
  // Admin's decisions stick: a head mod can't reinstate someone an admin paused or re-add someone an admin removed.
  await h.as(antic);
  await h.q(`select admin_set_moderator($1, true)`, [rando]);
  await h.q(`select admin_suspend_moderator($1, 'admin says no')`, [rando]);
  await h.as(head);
  await h.fails('head mod cannot undo an admin pause', `select admin_set_moderator($1, true)`, [rando]);
  // Removing first and adding back doesn't bury the admin's pause either.
  await h.as(head2);
  await h.q(`select admin_set_moderator($1, false)`, [rando]);
  await h.fails('remove-then-add cannot undo an admin pause', `select admin_set_moderator($1, true)`, [rando]);
  await h.as(antic);
  await h.q(`select admin_set_moderator($1, true)`, [rando]);
  await h.q(`select admin_suspend_moderator($1, 'admin says no')`, [rando]);
  await h.as(head);
  await h.q(`select admin_suspend_moderator($1, 'again')`, [rando]); // already paused: nothing happens
  await h.admin();
  h.eq('pausing a paused mod keeps the admin reason', (await h.one(`select suspended_reason r from site_moderators where user_id = $1`, [rando])).r, 'admin says no');
  await h.as(antic);
  await h.q(`select admin_set_moderator($1, false)`, [rando]);
  await h.as(head);
  await h.fails('head mod cannot re-add someone an admin removed', `select admin_set_moderator($1, true)`, [rando]);
  await h.q(`select admin_set_moderator($1, false)`, [rando]); // not a mod: no fake log row
  await h.admin();
  h.eq('no-op changes write nothing', (await h.one(`select count(*)::int n from mod_log where actor = $1 and target_id = $2`, [head, rando])).n, 0);
  const fresh = await h.signup('fresh365@test.dev', 'fresh365');
  await h.as(mod);
  await h.fails('a regular mod still cannot add mods', `select admin_set_moderator($1, true)`, [rando]);
  await h.fails('...or pause one', `select admin_suspend_moderator($1, 'x')`, [newbie]);
  // Daily cap: 4 changes so far (add, pause, reinstate=add, remove); 6 more are fine, the 11th is not.
  await h.as(head);
  for (let i = 0; i < 3; i++) { await h.q(`select admin_set_moderator($1, true)`, [fresh]); await h.q(`select admin_set_moderator($1, false)`, [fresh]); }
  await h.fails('10 changes a day, then stop', `select admin_set_moderator($1, true)`, [fresh]);

  // ---- pausing or removing a head mod takes the badge and role ----
  await h.as(antic);
  await h.q(`select admin_suspend_moderator($1, 'break')`, [head2]);
  await h.admin();
  h.eq('paused head mod: no head badge', (await h.one(`select coalesce('head_mod' = any(badges), false) v from profiles where id = $1`, [head2])).v, false);
  h.eq('paused head mod: no HQ role', (await h.one(`select count(*)::int n from member_roles where user_id = $1 and role_id = $2`, [head2, ROLE])).n, 0);
  await h.as(head2);
  h.eq('paused head mod is not head', (await h.one(`select is_head_mod() v`)).v, false);
  await h.as(antic);
  await h.q(`select admin_set_moderator($1, true)`, [head2]); // reinstate: still head
  await h.admin();
  h.eq('reinstated head mod gets both back', (await h.one(`select 'head_mod' = any(badges) b, (select count(*)::int from member_roles where user_id = $1 and role_id = $2) r from profiles where id = $1`, [head2, ROLE])),
    { b: true, r: 1 });
  await h.as(antic);
  await h.q(`select admin_set_head_mod($1, false)`, [head]);
  await h.admin();
  h.eq('unmade head mod keeps the mod badge only', (await h.one(`select badges from profiles where id = $1`, [head])).badges, ['mod']);
  h.eq('...and loses the HQ role', (await h.one(`select count(*)::int n from member_roles where user_id = $1 and role_id = $2`, [head, ROLE])).n, 0);
  await h.as(antic);
  await h.q(`select admin_set_moderator($1, false)`, [head2]);
  await h.admin();
  h.eq('removing a head mod clears both badges', (await h.one(`select coalesce(array_length(badges, 1), 0) n from profiles where id = $1`, [head2])).n, 0);
  h.eq('admin removals logged', (await h.one(`select count(*)::int n from mod_log where actor = $1 and action = 'mod_removed'`, [antic])).n, 2);
}
