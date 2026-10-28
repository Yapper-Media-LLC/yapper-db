// 317: the verified badge comes off when a person renames to a name that isn't their verified channel's, display
// name included. The name helpers are small stand-ins (lowercase letters and digits); the guard is the migration's.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '317_verified_rename_lock.sql'), 'utf8');

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists pronouns text;
alter table public.profiles add column if not exists accent_color text;
alter table public.profiles add column if not exists accent_color2 text;
alter table public.profiles add column if not exists verified_as text;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select coalesce(t ilike '%badword%', false) $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.brand_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.clean_name(t text) returns text language sql immutable as $$ select nullif(btrim(coalesce(t, '')), '') $$;
create or replace function public.verify_name_key(t text) returns text language sql immutable as $$ select lower(regexp_replace(coalesce(t, ''), '[^a-zA-Z0-9]', '', 'g')) $$;
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select false $$;
`;
// The two badge-protecting triggers around it, as live (Oct 20), so the clear is checked through the real order:
// profiles_0_protect runs first, profiles_protect_verified (definer, so current_user is the owner) after.
const TRIGGER = `
create or replace function public.protect_profile_columns() returns trigger language plpgsql set search_path to 'public' as $f$
begin
  if current_user = 'authenticated' and not public.is_site_admin() then new.verified_as := old.verified_as; end if;
  return new;
end $f$;
create or replace function public.protect_verified_as() returns trigger language plpgsql security definer set search_path to 'public' as $f$
begin
  if new.verified_as is distinct from old.verified_as and not public.is_site_admin() and current_user <> 'postgres' and current_user <> 'service_role' then
    new.verified_as := old.verified_as;
  end if;
  return new;
end $f$;
drop trigger if exists profiles_0_protect on public.profiles;
create trigger profiles_0_protect before update on public.profiles for each row execute function public.protect_profile_columns();
drop trigger if exists profiles_custom_guard on public.profiles;
create trigger profiles_custom_guard before insert or update on public.profiles for each row execute function public.profile_custom_guard();
drop trigger if exists profiles_protect_verified on public.profiles;
create trigger profiles_protect_verified before update on public.profiles for each row execute function public.protect_verified_as();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.db.exec(TRIGGER);
  await h.ok('317 re-runs cleanly', () => h.db.exec(MIG));

  const users = {};
  for (const n of ['amy', 'bob', 'cat', 'dan', 'eve', 'fay']) users[n] = await h.signup(`${n}@test.dev`, `${n}user`);
  await h.admin();
  // Verified as YouTube · MrBeast. Most match through the display name, fay through the username.
  for (const n of ['amy', 'bob', 'cat', 'dan', 'eve']) {
    await h.q(`update profiles set display_name = 'MrBeast', verified_as = 'YouTube · MrBeast' where id = $1`, [users[n]]);
  }
  await h.q(`update profiles set username = 'mrbeast', display_name = 'Jimmy', verified_as = 'YouTube · MrBeast' where id = $1`, [users.fay]);
  const badge = async (n) => (await h.one(`select verified_as from profiles where id = $1`, [users[n]])).verified_as;
  const as = async (n, sql) => { await h.as(users[n]); await h.q(sql, [users[n]]); await h.admin(); };

  await as('amy', `update profiles set display_name = 'Elon Musk' where id = $1`);
  h.eq('a new display name that is not the channel drops the badge', await badge('amy'), null);

  await as('bob', `update profiles set display_name = 'Mr. Beast 🎉' where id = $1`);
  h.eq('the same name styled differently keeps it', await badge('bob'), 'YouTube · MrBeast');

  await as('cat', `update profiles set bio = 'hello', pronouns = 'he/him' where id = $1`);
  h.eq('other profile edits keep it', await badge('cat'), 'YouTube · MrBeast');

  await as('dan', `update profiles set display_name = null where id = $1`);
  h.eq('clearing the display name shows a username that is not the channel: badge off', await badge('dan'), null);

  await as('eve', `update profiles set username = 'someoneelse' where id = $1`);
  h.eq('a username that is not the channel drops it (as before)', await badge('eve'), null);

  // A display name stored before the current cleaning rules (padded here) isn't a change on a bio-only save.
  await h.q(`update profiles set display_name = '  Jimmy  ' where id = $1`, [users.fay]);
  await h.db.exec('alter table public.profiles disable trigger profiles_custom_guard');
  await h.q(`update profiles set display_name = '  Jimmy  ' where id = $1`, [users.fay]);
  await h.db.exec('alter table public.profiles enable trigger profiles_custom_guard');
  await as('fay', `update profiles set bio = 'x', display_name = '  Jimmy  ' where id = $1`);
  h.eq('an old display name that never matched is fine while it stays', await badge('fay'), 'YouTube · MrBeast');
  await as('fay', `update profiles set display_name = 'Jimmy D' where id = $1`);
  h.eq('a new display name has to match, even when the username does', await badge('fay'), null);

  // Staff and the service role rename without touching the badge.
  await h.q(`update profiles set verified_as = 'YouTube · MrBeast' where id = $1`, [users.amy]);
  await h.q(`update profiles set display_name = 'Anything' where id = $1`, [users.amy]);
  h.eq('admin/service renames keep it', await badge('amy'), 'YouTube · MrBeast');
}
