// 279: any moderator can take back any warning and reset standing. Base 001..024, stand-ins for what the two functions
// touch (is_site_mod/is_staff, user_warnings, mod_log, mod_guard as "staff only, not on staff"), then 279 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create table if not exists public.user_warnings (
  id uuid primary key default gen_random_uuid(), user_id uuid not null, "by" uuid, reason text not null default '',
  created_at timestamptz default now(), seen_at timestamptz, removed_at timestamptz, removed_by uuid);
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
create or replace function public.mod_guard(act text, uid uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  if exists (select 1 from public.site_moderators where user_id = uid) then raise exception 'Not on staff'; end if;
end $$;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '279_mods_take_back_any_warning.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('279 re-runs cleanly', () => h.db.exec(MIG));

  const modA = await h.signup('a@test.dev', 'moda');
  const modB = await h.signup('b@test.dev', 'modb');
  const user = await h.signup('u@test.dev', 'someone');
  const user2 = await h.signup('u2@test.dev', 'someone2');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1), ($2)`, [modA, modB]);
  const w1 = (await h.one(`insert into user_warnings (user_id, "by", reason) values ($1, $2, 'False report') returning id`, [user, modA])).id;
  await h.q(`insert into user_warnings (user_id, "by", reason) values ($1, $2, 'one'), ($1, $3, 'two')`, [user2, modA, modB]);

  await h.as(user);
  await h.fails('a regular user can\'t remove a warning', `select mod_remove_warning($1)`, [w1]);
  await h.fails('a regular user can\'t reset standing', `select mod_reset_standing($1)`, [user2]);

  await h.as(modB);
  await h.ok('another mod removes a warning they didn\'t give', () => h.q(`select mod_remove_warning($1)`, [w1]));
  await h.admin();
  h.eq('removed and attributed', await h.one(`select removed_at is not null gone, removed_by = $2 by_b from user_warnings where id = $1`, [w1, modB]),
    { gone: true, by_b: true });

  await h.as(modB);
  h.eq('reset standing clears everyone\'s warnings', (await h.one(`select mod_reset_standing($1) n`, [user2])).n, 2);
  await h.admin();
  h.eq('no active warnings left', (await h.one(`select count(*)::int n from user_warnings where user_id = $1 and removed_at is null`, [user2])).n, 0);
  h.eq('both logged', (await h.one(`select count(*)::int n from mod_log where action = 'unwarn' and actor = $1`, [modB])).n, 2);

  await h.q(`insert into user_warnings (user_id, "by", reason) values ($1, $2, 'staff')`, [modA, modB]);
  await h.as(modB);
  await h.fails('mods still can\'t reset another mod (mod_guard)', `select mod_reset_standing($1)`, [modA]);
}
