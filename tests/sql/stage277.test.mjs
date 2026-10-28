// 277: a username a moderator resets is held for 30 days. Same base as 246 (001..024, flags 031/041, the live
// is_staff/daily-limit stand-ins), then 246 (holds), stand-ins for what mod_reset_profile touches (the profile columns
// it wipes, mod_log, and mod_guard as "staff only"), then 277 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists banner_path text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists pronouns text;
alter table public.profiles add column if not exists links jsonb;
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
create or replace function public.mod_guard(act text, uid uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
end $$;
`;

const TAKEN = /^That username is taken$/;

export default async function (h) {
  const HOLDS = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '246_username_holds.sql'), 'utf8');
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '277_mod_reset_holds_name.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(HOLDS);
  await h.db.exec(MIG);
  await h.ok('277 re-runs cleanly', () => h.db.exec(MIG));

  const refused = async (name, sql, params, re) => {
    let m = null;
    try { await h.db.query(sql, params); } catch (e) { m = e.message; }
    if (!m || !re.test(m)) throw new Error(`✗ ${name}: expected ${re}, got ${m ?? 'success'}`);
    h.passed++;
  };

  const mod = await h.signup('mod@test.dev', 'mod');
  const bad = await h.signup('bad@test.dev', 'RudeName');
  const other = await h.signup('other@test.dev', 'other');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'username_limits'`);

  await h.as(other);
  await h.fails('non-staff can\'t reset a profile', `select mod_reset_profile($1, array['username'], 'nope')`, [bad]);

  await h.as(mod);
  await h.ok('mod resets the username', () => h.q(`select mod_reset_profile($1, array['username'], 'Sexual name')`, [bad]));
  await h.admin();
  const p = await h.one(`select username from profiles where id = $1`, [bad]);
  h.eq('renamed to a placeholder', /^user[0-9a-f]{8}$/.test(p.username), true);
  const hold = await h.one(`select user_id, until between now() + interval '29 days 23 hours' and now() + interval '30 days 1 minute' ok
    from username_holds where name_key = 'rudename'`);
  h.eq('old name held by the moderator for 30 days', hold, { user_id: mod, ok: true });
  h.eq('logged', (await h.one(`select count(*)::int n from mod_log where action = 'profile_reset' and target_id = $1`, [bad])).n, 1);

  await h.as(bad);
  await refused('the person can\'t take it back', `update profiles set username = 'RudeName' where id = $1`, [bad], TAKEN);
  await h.as(other);
  await refused('nobody else can take it', `update profiles set username = 'rudename' where id = $1`, [other], TAKEN);
  await h.as(null);
  h.eq('username_taken says taken', (await h.one(`select username_taken('RUDENAME') t`)).t, true);

  // Resetting other parts only holds nothing.
  await h.as(mod);
  await h.q(`select mod_reset_profile($1, array['bio'], 'bad bio')`, [other]);
  await h.admin();
  h.eq('bio-only reset holds no name', await h.one(`select 1 x from username_holds where name_key = 'other'`), undefined);
}
