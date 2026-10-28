// 410: the verified badge only comes off for a new username that isn't the verified channel's; display names are free.
// Same stand-ins and triggers as stage317, with 410's guard.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '410_verified_display_name_free.sql'), 'utf8');

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
  await h.ok('410 re-runs cleanly', () => h.db.exec(MIG));

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
  h.eq('a new display name keeps the badge', await badge('amy'), 'YouTube · MrBeast');

  await as('cat', `update profiles set bio = 'hello', pronouns = 'he/him' where id = $1`);
  h.eq('other profile edits keep it', await badge('cat'), 'YouTube · MrBeast');

  await as('dan', `update profiles set display_name = null where id = $1`);
  h.eq('clearing the display name keeps it', await badge('dan'), 'YouTube · MrBeast');

  await as('eve', `update profiles set username = 'someoneelse' where id = $1`);
  h.eq('a username that is not the channel drops it', await badge('eve'), null);

  await as('bob', `update profiles set username = 'mr_beast' where id = $1`);
  h.eq('a username that is the channel styled differently keeps it', await badge('bob'), 'YouTube · MrBeast');

  await as('fay', `update profiles set display_name = 'Jimmy D' where id = $1`);
  h.eq('verified through the username: a new display name keeps it', await badge('fay'), 'YouTube · MrBeast');
  await as('fay', `update profiles set username = 'jimmyd' where id = $1`);
  h.eq('...but a new username that is not the channel drops it', await badge('fay'), null);

  // Staff and the service role rename without touching the badge.
  await h.q(`update profiles set username = 'whatever', verified_as = 'YouTube · MrBeast' where id = $1`, [users.eve]);
  h.eq('admin/service renames keep it', await badge('eve'), 'YouTube · MrBeast');
}
