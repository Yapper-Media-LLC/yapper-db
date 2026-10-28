// 226: ban appeals. PGlite can't replay every migration, so: 001..024, flags (031, 041), small stand-ins for the
// live mod pieces 226 calls (is_staff, mod_guard, site_unban as live, Oct 18), then 226 twice (re-runnable).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid,
  message_id uuid, reason text, created_at timestamptz not null default now());
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
end $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;
create or replace function public.site_unban(uid uuid) returns void language plpgsql security definer set search_path to 'public' as $function$
declare b public.site_bans;
begin
  select * into b from public.site_bans where user_id = uid;
  if b.user_id is null then return; end if;
  if not public.is_site_admin() then
    if not public.is_site_mod() then raise exception 'Moderators only'; end if;
    if b.banned_by is not null and b.expires_at is null then raise exception 'Only an admin can lift a confirmed ban'; end if;
    perform public.mod_guard('unban', uid, null);
  end if;
  update public.site_bans set expires_at = now() where user_id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unban', uid, coalesce(b.reason, ''));
end; $function$;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '226_ban_appeals.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('226 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');   // banned (automatic: no banned_by)
  const bob = await h.signup('bob@test.dev', 'bob');   // banned (confirmed by an admin)
  const cat = await h.signup('cat@test.dev', 'cat');   // not banned
  const mod = await h.signup('mod@test.dev', 'mod');
  const adm = await h.signup('adm@test.dev', 'adm');

  await h.admin();
  h.eq('flag exists in test mode', (await h.one(`select mode from feature_flags where key = 'ban_appeals'`)).mode, 'test');
  await h.q(`insert into site_admins (user_id) values ($1)`, [adm]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'auto: spam')`, [amy]);
  await h.q(`insert into site_bans (user_id, reason, banned_by) values ($1, 'slurs', $2)`, [bob, adm]);

  await h.as(amy);
  h.eq('appeals closed while the flag is off for me', (await h.one(`select my_ban_appeal() r`)).r, { open: false, appeal: null });
  await h.fails('cannot appeal while the flag is off', `select submit_ban_appeal('please let me back in')`);

  await h.admin();
  await h.q(`update feature_flags set users = array[$1, $2, $3]::uuid[] where key = 'ban_appeals'`, [amy, bob, cat]);

  await h.as(amy);
  await h.fails('too short', `select submit_ban_appeal('sorry')`);
  await h.ok('banned person appeals', () => h.q(`select submit_ban_appeal('It was a mistake, I only posted one gif')`));
  await h.fails('one appeal per ban', `select submit_ban_appeal('Again, please, it was a mistake')`);
  const mine = (await h.one(`select my_ban_appeal() r`)).r;
  h.eq('my appeal shows as pending', [mine.open, mine.appeal.status], [true, 'pending']);
  await h.fails('no direct table reads', `select * from ban_appeals`);
  await h.fails('no direct table writes', `update ban_appeals set status = 'approved'`);
  await h.fails('not staff: no list', `select staff_ban_appeals('pending')`);

  await h.as(cat);
  await h.fails('not banned: cannot appeal', `select submit_ban_appeal('I just want to try this out')`);

  await h.as(bob);
  await h.ok('confirmed ban can be appealed too', () => h.q(`select submit_ban_appeal('I was hacked, that was not me')`));

  await h.as(mod);
  const list = (await h.one(`select staff_ban_appeals('pending') r`)).r;
  h.eq('mod sees both, oldest first', list.map((a) => a.username), ['amy', 'bob']);
  h.eq('mod can lift the automatic ban but not the confirmed one', list.map((a) => a.can_lift), [true, false]);
  const [aAmy, aBob] = list.map((a) => a.id);
  await h.fails('mod cannot lift a confirmed ban', `select decide_ban_appeal($1, true, null)`, [aBob]);
  h.eq('failed lift left it pending', (await h.one(`select staff_ban_appeals('pending') r`)).r.length, 2);
  await h.ok('mod accepts amy', () => h.q(`select decide_ban_appeal($1, true, 'ok, welcome back')`, [aAmy]));
  await h.fails('cannot decide twice', `select decide_ban_appeal($1, false, null)`, [aAmy]);

  await h.admin();
  h.eq('amy is unbanned', (await h.one(`select is_site_banned($1) b`, [amy])).b, false);
  h.eq('unban logged', (await h.one(`select count(*)::int n from mod_log where action = 'unban' and target_id = $1`, [amy])).n, 1);

  await h.as(adm);
  await h.ok('admin denies bob with a note', () => h.q(`select decide_ban_appeal($1, false, 'We checked the logs, it was you')`, [aBob]));
  h.eq('decided list has both', (await h.one(`select staff_ban_appeals('decided') r`)).r.length, 2);

  await h.as(bob);
  const b = (await h.one(`select my_ban_appeal() r`)).r.appeal;
  h.eq('bob sees the denial and note', [b.status, b.staff_note], ['denied', 'We checked the logs, it was you']);

  await h.admin();
  await h.q(`update site_bans set created_at = now() + interval '1 second', expires_at = null where user_id = $1`, [bob]);
  await h.as(bob);
  h.eq('a new ban starts with no appeal', (await h.one(`select my_ban_appeal() r`)).r.appeal, null);
  await h.ok('a new ban can be appealed again', () => h.q(`select submit_ban_appeal('This new ban is wrong too')`));

  // Re-ban while an appeal is pending: approving the old one must not lift the new ban.
  await h.admin();
  await h.q(`update site_bans set expires_at = null, created_at = now() - interval '1 hour' where user_id = $1`, [amy]);
  await h.as(amy);
  await h.ok('amy appeals her new ban', () => h.q(`select submit_ban_appeal('Second time, still a mistake')`));
  await h.as(mod);
  const old = (await h.one(`select staff_ban_appeals('pending') r`)).r.find((a) => a.username === 'amy');
  await h.admin();
  await h.q(`update site_bans set created_at = now() where user_id = $1`, [amy]);
  await h.as(mod);
  h.eq('old appeal now shows as not banned', (await h.one(`select staff_ban_appeals('pending') r`)).r.find((a) => a.id === old.id).still_banned, false);
  await h.fails('approving an appeal for an older ban fails', `select decide_ban_appeal($1, true, null)`, [old.id]);
  await h.ok('it can still be denied', () => h.q(`select decide_ban_appeal($1, false, null)`, [old.id]));
  await h.admin();
  h.eq('amy is still banned', (await h.one(`select is_site_banned($1) b`, [amy])).b, true);

  await h.as(null);
  await h.fails('anon cannot appeal', `select submit_ban_appeal('hello hello hello')`);
}
