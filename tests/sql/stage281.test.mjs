// 281: copyright strikes and evidence freeze. Stand-ins for what 281 runs next to (PGlite stops at 024).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '281_copyright_strikes_freeze.sql'), 'utf8');

export default async function (h) {
  const failsWith = async (name, re, sql, params = []) => {
    let msg = null;
    try { await h.db.query(sql, params); } catch (e) { msg = e.message; }
    h.eq(name, msg !== null && re.test(msg) ? 'refused' : msg, 'refused');
  };
  await h.admin();
  await h.db.exec(`
    create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
      mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
    create table if not exists public.mod_log (id bigserial primary key, actor uuid references public.profiles (id), action text, target_id uuid references public.profiles (id), reason text, created_at timestamptz default now());
    create table if not exists public.site_moderators (user_id uuid primary key);
    create table if not exists public.site_admins (user_id uuid primary key);
    create table if not exists public.site_bans (user_id uuid primary key, reason text, banned_by uuid, created_at timestamptz default now(), expires_at timestamptz);
    alter table public.site_bans add column if not exists expires_at timestamptz;
    create table if not exists public.media_purge (bucket text, path text, queued_at timestamptz default now(), done_at timestamptz, primary key (bucket, path));
    create table if not exists public.app_settings (id int primary key default 1, default_server_id uuid);
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.site_moderators where user_id = auth.uid()) or exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
    create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
CREATE OR REPLACE FUNCTION public.delete_my_account()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth'
AS $function$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'You need to be logged in';
  end if;
  if exists (
    select 1 from public.app_settings a
    join public.servers s on s.id = a.default_server_id
    where s.owner_id = uid
  ) then
    raise exception 'nope';
  end if;
  raise exception 'deleted';
end;
$function$;`);
  await h.db.exec(`
CREATE OR REPLACE FUNCTION public.site_ban(uid uuid, why text DEFAULT ''::text, wipe boolean DEFAULT false)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  insert into public.site_bans (user_id, reason, banned_by) values (uid, left(coalesce(why, ''), 500), auth.uid()) on conflict (user_id) do nothing;
  if wipe then
    raise exception 'wiped';
  end if;
end;
$function$;
CREATE OR REPLACE FUNCTION public.mod_purge_messages(uid uuid, hours integer, why text)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare n int; r text := left(btrim(coalesce(why, '')), 500);
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  perform public.mod_guard('purge', uid, r);
  return 0;
end $function$;
create or replace function public.mod_guard(a text, t uuid, w text) returns void language sql as $$ select $$;
`);
  await h.db.exec(MIG);
  await h.ok('281 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const mod = await h.signup('mod@test.dev', 'mod');
  const boss = await h.signup('boss@test.dev', 'boss');
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  await h.q(`insert into site_admins values ($1)`, [boss]);
  await h.q(`insert into media_purge (bucket, path) values ('avatars', $1), ('avatars', $2)`, [`${amy}/a.png`, `${mod}/b.png`]);

  await h.as(amy);
  await failsWith('users can’t add strikes', /Staff only/, `select staff_add_copyright_strike($1, null, 'x notice')`, [mod]);
  await failsWith('users can’t freeze', /Admins only/, `select admin_freeze_account($1, 'why', true)`, [mod]);
  await failsWith('users can’t read strikes', /permission denied/, `select * from copyright_strikes`);

  await h.as(mod);
  h.eq('strike 1', (await h.one(`select staff_add_copyright_strike($1, null, 'Notice from ACME, song X, Oct 19') n`, [amy])).n, 1);
  h.eq('strike 2', (await h.one(`select staff_add_copyright_strike($1, null, 'Notice from ACME, song Y') n`, [amy])).n, 2);
  const s3 = await h.one(`select staff_add_copyright_strike($1, null, 'Notice from ACME, song Z') n`, [amy]);
  h.eq('strike 3', s3.n, 3);
  const first = (await h.q(`select id from staff_copyright_strikes($1) order by created_at limit 1`, [amy]))[0].id;
  await h.ok('take one back', () => h.q(`select staff_remove_copyright_strike($1, 'counter-notice')`, [first]));
  h.eq('back to 2 counted', (await h.one(`select staff_add_copyright_strike($1, null, 'Another one') n`, [amy])).n, 3);
  await failsWith('mods can’t freeze', /Admins only/, `select admin_freeze_account($1, 'why', true)`, [amy]);

  await h.as(boss);
  await h.ok('admin freezes and locks', () => h.q(`select admin_freeze_account($1, 'police request', true)`, [amy]));
  await h.admin();
  h.eq('locked out', (await h.one(`select count(*)::int n from site_bans where user_id = $1`, [amy])).n, 1);
  h.eq('their pending purge is cancelled', (await h.one(`select count(*)::int n from media_purge where path like $1`, [`${amy}/%`])).n, 0);
  h.eq('others’ purge untouched', (await h.one(`select count(*)::int n from media_purge where path like $1`, [`${mod}/%`])).n, 1);
  await h.as(amy);
  await failsWith('frozen account can’t delete itself', /locked while we look/, `select delete_my_account()`);
  await h.as(boss);
  await failsWith('ban with wipe refused while frozen', /frozen to keep evidence/, `select site_ban($1, 'x', true)`, [amy]);
  await h.as(mod);
  await failsWith('mod purge refused while frozen', /frozen to keep evidence/, `select mod_purge_messages($1, 24, 'x')`, [amy]);
  await h.as(boss);
  await h.ok('unfreeze', () => h.q(`select admin_unfreeze_account($1)`, [amy]));
  await h.admin();
  h.eq('held purge put back', (await h.one(`select count(*)::int n from media_purge where path like $1`, [`${amy}/%`])).n, 1);
  await h.as(mod);
  await h.ok('purge works again after unfreeze', () => h.q(`select mod_purge_messages($1, 24, 'x')`, [amy]));
  await h.as(amy);
  await failsWith('after unfreeze delete goes ahead', /deleted/, `select delete_my_account()`);
}
