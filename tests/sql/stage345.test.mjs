// 345: community decorations and profile effects. Stand-ins for the live pieces it calls (the scan guard, staff and
// ban checks, the effect trigger from 101, the decoration CHECK from 104).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '345_community_decos.sql'), 'utf8');

export const STANDINS = `
alter table public.profiles add column if not exists avatar_deco text;
alter table public.profiles add column if not exists profile_effect text;
alter table public.profiles drop constraint if exists avatar_deco_known;
alter table public.profiles add constraint avatar_deco_known check (avatar_deco is null or avatar_deco in ('flames','crown','halo','horns','cat','wings','headphones','laurel','snow','hearts','stars','lightning'));
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
create table if not exists public.site_admins (user_id uuid primary key);
create table if not exists public.site_moderators (user_id uuid primary key);
create table if not exists public.banned (user_id uuid primary key);
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.banned where user_id = uid) $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (auth.uid() = any(users) or exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers)))) from public.feature_flags where key = k), false);
$$;
create table if not exists public.media_ok_paths (path text primary key);
create or replace function public.media_ok(b text, p text) returns boolean language sql stable as $$ select exists (select 1 from public.media_ok_paths where path = p) $$;
create or replace function public.require_scanned_media() returns trigger language plpgsql security definer set search_path = public as $$
declare v text := to_jsonb(new) ->> tg_argv[0];
begin
  if v is not null and not exists (select 1 from public.media_ok_paths where path = v) then
    raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation';
  end if;
  return new;
end; $$;
create or replace function public.profile_effect_plus_only() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.profile_effect is not null and new.profile_effect not in ('glow', 'rainbow', 'fire', 'ice', 'gold', 'sparkle', 'galaxy', 'neon', 'hearts', 'toxic') then raise exception 'Unknown profile effect'; end if;
  return new;
end; $$;
drop trigger if exists profile_effect_plus_only on public.profiles;
create trigger profile_effect_plus_only before update of profile_effect on public.profiles for each row execute function public.profile_effect_plus_only();
grant update (avatar_deco, profile_effect) on public.profiles to authenticated;
create table if not exists public.pinged (id uuid);
create or replace function public.rt_profile_changed(uids uuid[]) returns void language sql security definer set search_path = public as $$
  insert into public.pinged select u from unnest(uids) u;
$$;
-- A profile guard that refuses one particular profile (like a stored name today's rules don't allow).
create or replace function public.picky_guard() returns trigger language plpgsql as $$
begin if new.username = 'stubborn' then raise exception 'nope'; end if; return new; end $$;
drop trigger if exists picky_guard on public.profiles;
create trigger picky_guard before update on public.profiles for each row execute function public.picky_guard();
-- Like not_site_banned / require_mfa: about the person making the change.
create or replace function public.actor_guard() returns trigger language plpgsql as $$
begin if auth.uid() is not null and exists (select 1 from public.banned where user_id = auth.uid()) then raise exception 'banned'; end if; return new; end $$;
drop trigger if exists actor_guard on public.profiles;
create trigger actor_guard before update on public.profiles for each row execute function public.actor_guard();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('345 re-runs cleanly', () => h.db.exec(MIG));

  const art = await h.signup('art@test.dev', 'artist');
  const fan = await h.signup('fan@test.dev', 'fan');
  const mod = await h.signup('mod@test.dev', 'mod');
  const out = await h.signup('out@test.dev', 'outsider');
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  await h.q(`update feature_flags set users = array[$1, $2, $3]::uuid[] where key = 'community_decos'`, [art, fan, mod]);
  const ok = async (p) => { await h.admin(); await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [p]); };
  const submit = async (who, kind, name, path) => { await h.as(who); return (await h.one(`select submit_community_deco($1, $2, $3) id`, [kind, name, path])).id; };

  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'community_decos'`)).mode, 'test');

  // ---------- submitting ----------
  await ok(`${art}/a.png`);
  await h.as(out);
  await h.fails('flag off: refused', `select submit_community_deco('deco', 'Nope', $1)`, [`${out}/x.png`]);
  await h.as(art);
  await h.fails('someone else\'s folder: refused', `select submit_community_deco('deco', 'Stolen', $1)`, [`${fan}/a.png`]);
  await h.fails('picture not checked yet: refused', `select submit_community_deco('deco', 'Unchecked', $1)`, [`${art}/raw.png`]);
  await h.fails('name too short', `select submit_community_deco('deco', 'x', $1)`, [`${art}/a.png`]);
  await h.fails('bad kind', `select submit_community_deco('hat', 'Hat', $1)`, [`${art}/a.png`]);
  const d1 = await submit(art, 'deco', 'Leaf crown', `${art}/a.png`);
  await h.fails('the same picture twice: refused', `select submit_community_deco('deco', 'Again', $1)`, [`${art}/a.png`]);
  await ok(`${art}/b.png`); await ok(`${art}/c.gif`); await ok(`${art}/d.png`);
  const d2 = await submit(art, 'deco', 'Thorns', `${art}/b.png`);
  const e1 = await submit(art, 'effect', 'Sparkle storm', `${art}/c.gif`);
  await h.as(art);
  await h.fails('a 4th waiting: refused', `select submit_community_deco('deco', 'Fourth', $1)`, [`${art}/d.png`]);
  await h.fails('no direct inserts', `insert into community_decos (kind, name, artist_id, path) values ('deco', 'Sneaky', $1, $2)`, [art, `${art}/d.png`]);
  await h.fails('no direct approval', `update community_decos set status = 'approved' where id = $1`, [d1]);

  // ---------- who sees what ----------
  await h.as(fan);
  h.eq('others don\'t see waiting ones', (await h.q(`select id from community_decos`)).length, 0);
  await h.as(art);
  h.eq('the artist sees their own', (await h.q(`select id from community_decos`)).length, 3);
  await h.as(mod);
  h.eq('staff see everything', (await h.q(`select id from community_decos`)).length, 3);

  // ---------- wearing ----------
  await h.as(fan);
  await h.fails('can\'t wear one that isn\'t approved', `update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/a.png`, fan]);
  await h.ok('built-in decorations still work', () => h.q(`update profiles set avatar_deco = 'crown' where id = $1`, [fan]));
  await h.fails('unknown built-in refused', `update profiles set avatar_deco = 'tophat' where id = $1`, [fan]);
  await h.ok('built-in effects still work', () => h.q(`update profiles set profile_effect = 'glow' where id = $1`, [fan]));
  await h.fails('unknown effect refused', `update profiles set profile_effect = 'smoke' where id = $1`, [fan]);

  // ---------- review ----------
  await h.as(fan);
  await h.fails('not staff: can\'t review', `select review_community_deco($1, 'approved', '')`, [d1]);
  await h.as(mod);
  await h.fails('turning down needs a reason', `select review_community_deco($1, 'rejected', '')`, [d2]);
  await h.ok('mod approves', () => h.q(`select review_community_deco($1, 'approved', '')`, [d1]));
  await h.ok('mod approves the effect', () => h.q(`select review_community_deco($1, 'approved', '')`, [e1]));
  await h.ok('mod turns one down with a reason', () => h.q(`select review_community_deco($1, 'rejected', 'covers the avatar')`, [d2]));
  await h.admin();
  h.eq('logged for staff', (await h.q(`select action from mod_log order by action`)).map((r) => r.action), ['deco_approved', 'deco_approved', 'deco_rejected']);
  await h.q(`insert into site_moderators values ($1)`, [art]);
  await h.as(art);
  await h.fails('nobody reviews their own', `select review_community_deco($1, 'removed', 'testing')`, [d1]);
  await h.admin();
  await h.q(`delete from site_moderators where user_id = $1`, [art]);

  await h.as(fan);
  h.eq('approved ones are visible to everyone', (await h.q(`select name from community_decos order by name`)).map((r) => r.name), ['Leaf crown', 'Sparkle storm']);
  await h.ok('can wear an approved decoration', () => h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/a.png`, fan]));
  await h.ok('can wear an approved effect', () => h.q(`update profiles set profile_effect = $1 where id = $2`, [`c:${art}/c.gif`, fan]));
  await h.fails('an effect can\'t be worn as a decoration', `update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/c.gif`, fan]);
  await h.fails('a turned-down one can\'t be worn', `update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/b.png`, fan]);

  // ---------- taking down ----------
  await h.as(mod);
  await h.ok('mod removes the decoration', () => h.q(`select review_community_deco($1, 'removed', 'not their art')`, [d1]));
  await h.admin();
  h.eq('taken off everyone wearing it', (await h.one(`select avatar_deco, profile_effect from profiles where id = $1`, [fan])), { avatar_deco: null, profile_effect: `c:${art}/c.gif` });
  await h.as(art);
  await h.ok('the artist takes down their effect', () => h.q(`select withdraw_community_deco($1)`, [e1]));
  await h.admin();
  h.eq('and it comes off too', (await h.one(`select profile_effect from profiles where id = $1`, [fan])).profile_effect, null);
  await h.as(fan);
  await h.fails('someone else can\'t withdraw it', `select withdraw_community_deco($1)`, [d2]);

  // ---------- staff names stay with staff ----------
  await h.as(fan);
  await h.fails('others can\'t read who reviewed it', `select reviewed_by from community_decos`);

  // ---------- a removed one stays down ----------
  await h.as(mod);
  await h.fails('can\'t approve a taken-down one again', `select review_community_deco($1, 'approved', '')`, [d1]);

  // ---------- removal reaches everyone, even past a picky profile ----------
  const stub = await h.signup('stub@test.dev', 'stubborn');
  const fan2 = await h.signup('fan2@test.dev', 'fan2');
  await h.admin();
  await ok(`${art}/e.png`);
  await h.q(`update feature_flags set users = users || array[$1, $2]::uuid[] where key = 'community_decos'`, [stub, fan2]);
  const d3 = await submit(art, 'deco', 'Vines', `${art}/e.png`);
  await h.as(mod); await h.q(`select review_community_deco($1, 'approved', '')`, [d3]);
  await h.as(fan2); await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/e.png`, fan2]);
  await h.admin();
  await h.q(`alter table profiles disable trigger picky_guard`);
  await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/e.png`, stub]);
  await h.q(`alter table profiles enable trigger picky_guard`);
  await h.q(`delete from pinged`);
  await h.as(mod);
  await h.ok('removal goes through though one profile won\'t save', () => h.q(`select review_community_deco($1, 'removed', 'copied art')`, [d3]));
  await h.admin();
  h.eq('off the others, kept on the picky one', (await h.q(`select username, avatar_deco from profiles where id in ($1, $2) order by username`, [fan2, stub])).map((r) => [r.username, r.avatar_deco]),
    [['fan2', null], ['stubborn', `c:${art}/e.png`]]);
  h.eq('the realtime cache is told', (await h.q(`select id from pinged`)).map((r) => r.id), [fan2]);

  // A banned artist taking theirs down still takes it off everyone (the guard is about who asks).
  await ok(`${art}/f.png`);
  const d4 = await submit(art, 'deco', 'Moss', `${art}/f.png`);
  await h.as(mod); await h.q(`select review_community_deco($1, 'approved', '')`, [d4]);
  await h.as(fan2); await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/f.png`, fan2]);
  await h.admin(); await h.q(`insert into banned values ($1)`, [art]);
  await h.as(art);
  await h.ok('banned artist withdraws', () => h.q(`select withdraw_community_deco($1)`, [d4]));
  await h.admin();
  h.eq('and it comes off', (await h.one(`select avatar_deco from profiles where id = $1`, [fan2])).avatar_deco, null);
  await h.q(`delete from banned where user_id = $1`, [art]);

  // An artist's account deleted: their approved ones come off everyone.
  await ok(`${art}/g.png`);
  const d5 = await submit(art, 'deco', 'Ferns', `${art}/g.png`);
  await h.as(mod); await h.q(`select review_community_deco($1, 'approved', '')`, [d5]);
  await h.as(fan2); await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/g.png`, fan2]);
  await h.admin();
  await h.q(`delete from community_decos where artist_id = $1`, [art]);
  h.eq('rows gone: off everyone', (await h.one(`select avatar_deco from profiles where id = $1`, [fan2])).avatar_deco, null);

  // The real path: the artist's profile deleted (cascade), while they and a fan both wear it.
  const art2 = await h.signup('art2@test.dev', 'artist2');
  await h.admin();
  await h.q(`update feature_flags set users = users || array[$1]::uuid[] where key = 'community_decos'`, [art2]);
  await ok(`${art2}/h.png`);
  const d6 = await submit(art2, 'deco', 'Petals', `${art2}/h.png`);
  await h.as(mod); await h.q(`select review_community_deco($1, 'approved', '')`, [d6]);
  for (const who of [art2, fan2]) { await h.as(who); await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art2}/h.png`, who]); }
  await h.admin();
  await h.ok('deleting the artist\'s profile goes through', () => h.q(`delete from profiles where id = $1`, [art2]));
  h.eq('and it comes off the fan', (await h.one(`select avatar_deco from profiles where id = $1`, [fan2])).avatar_deco, null);

  // ---------- bans and grants ----------
  await h.admin();
  await h.q(`insert into banned values ($1)`, [art]);
  await h.as(art);
  await h.fails('banned: can\'t submit', `select submit_community_deco('deco', 'Banned', $1)`, [`${art}/d.png`]);
  await h.admin();
  const can = async (role, fn) => (await h.one(`select has_function_privilege($1, 'public.${fn}', 'execute') ok`, [role])).ok;
  h.eq('logged out: no functions', [await can('anon', 'submit_community_deco(text, text, text)'), await can('anon', 'review_community_deco(uuid, text, text)')], [false, false]);
  h.eq('nobody calls unwear directly', await can('authenticated', 'community_deco_unwear(text)'), false);
}
