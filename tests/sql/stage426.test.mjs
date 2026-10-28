// 426: approving a decoration gives the artist the Artist badge even when the reviewer's session isn't 2FA-verified
// (require_mfa on profiles refused the badge update, and the function swallowed it). Plus the backfill.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '426_artist_badge_mfa.sql'), 'utf8');

// Live-shaped stand-ins: auth.jwt reads the claims like Supabase's, require_mfa is the live trigger body with a
// table of who has 2FA set up, mod_log and the deco tables with the columns the function uses.
const STANDINS = `
create or replace function auth.jwt() returns jsonb language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''), nullif(current_setting('request.jwt.claims', true), ''))::jsonb $f$;
grant execute on function auth.jwt() to anon, authenticated;
alter table public.profiles add column if not exists badges text[] not null default '{}';
create table if not exists public.mfa_on (user_id uuid primary key);
create table if not exists public.staff (user_id uuid primary key);
create table if not exists public.banned (user_id uuid primary key);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
create table if not exists public.community_decos (id uuid primary key default gen_random_uuid(), artist_id uuid, name text, path text,
  status text default 'pending', review_note text, reviewed_by uuid, reviewed_at timestamptz);
create table if not exists public.community_deco_checks (deco_id uuid, verdict text, cleared_at timestamptz);
create table if not exists public.rt_calls (ids uuid[]);
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $f$
  select exists (select 1 from public.staff where user_id = auth.uid()) $f$;
create or replace function public.is_site_mod() returns boolean language sql stable as $f$ select false $f$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $f$
  select exists (select 1 from public.banned where user_id = uid) $f$;
create or replace function public.media_ok(b text, p text) returns boolean language sql stable as $f$ select true $f$;
create or replace function public.community_deco_unwear(p text) returns void language sql as $f$ select $f$;
create or replace function public.rt_profile_changed(ids uuid[]) returns void language sql security definer set search_path = public as $f$
  insert into public.rt_calls values (ids) $f$;
create or replace function public.require_mfa() returns trigger language plpgsql security definer set search_path = public as $f$
begin
  if auth.uid() is not null
     and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2'
     and exists (select 1 from public.mfa_on f where f.user_id = auth.uid()) then
    raise exception 'Finish two-factor sign-in first.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $f$;
drop trigger if exists profiles_require_mfa on public.profiles;
create trigger profiles_require_mfa before update on public.profiles for each row execute function public.require_mfa();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);

  const boss = await h.signup('boss@test.dev', 'boss');
  const art = await h.signup('art@test.dev', 'art');
  const old = await h.signup('old@test.dev', 'old');
  const gone = await h.signup('gone@test.dev', 'gone');
  const strip = await h.signup('strip@test.dev', 'strip');
  await h.admin();
  await h.q(`insert into staff values ($1)`, [boss]);
  await h.q(`insert into mfa_on values ($1)`, [boss]);
  await h.q(`insert into banned values ($1)`, [gone]);
  const d1 = (await h.one(`insert into community_decos (artist_id, name, path) values ($1, 'Ring', 'a/ring.png') returning id`, [art])).id;
  // Approved before the fix without the badge (the bug), one banned, one whose badge staff took off.
  await h.q(`insert into community_decos (artist_id, name, path, status) values ($1, 'Old', 'o/x.png', 'approved'), ($2, 'Gone', 'g/x.png', 'approved'), ($3, 'Strip', 's/x.png', 'approved')`, [old, gone, strip]);
  await h.q(`insert into mod_log (actor, action, target_id, reason) values ($1, 'badge_removed', $2, 'artist')`, [boss, strip]);

  await h.db.exec(MIG);
  await h.ok('426 re-runs cleanly', () => h.db.exec(MIG));

  const badges = async (id) => (await h.one(`select badges from profiles where id = $1`, [id])).badges;
  h.eq('backfill gives the skipped artist the badge', await badges(old), ['artist']);
  h.eq('backfill skips a banned artist', await badges(gone), []);
  h.eq('backfill skips one staff took the badge from', await badges(strip), []);
  h.eq('backfill logs once (re-run adds nothing)', (await h.one(`select count(*)::int n from mod_log where action = 'badge_auto' and target_id = $1`, [old])).n, 1);

  // The reviewer has 2FA but this session is aal1 (the Oct 22 batch): approving still gives the badge.
  await h.as(boss);
  await h.db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: boss, aal: 'aal1' })]);
  await h.fails('the reviewer\'s own aal1 session is still refused on profiles', `update profiles set badges = '{}' where id = '${boss}'`);
  await h.ok('approve as an aal1 reviewer', () => h.q(`select public.review_community_deco($1, 'approved')`, [d1]));
  h.eq('the artist got the badge', await badges(art), ['artist']);
  const log = await h.one(`select actor, reason from mod_log where action = 'badge_auto' and target_id = $1`, [art]);
  h.eq('badge_auto is logged as the reviewer (claims put back)', [log.actor, log.reason], [boss, 'artist']);
  h.eq('the reviewer\'s claims are back afterwards', (await h.one(`select auth.uid() u, auth.jwt() ->> 'aal' a`)), { u: boss, a: 'aal1' });
  h.eq('realtime told about the artist', (await h.one(`select count(*)::int n from rt_calls where $1 = any(ids)`, [art])).n, 1);
  h.eq('approval itself went through', (await h.one(`select status, reviewed_by from community_decos where id = $1`, [d1])), { status: 'approved', reviewed_by: boss });

  // Still staff only.
  await h.admin();
  const d2 = (await h.one(`insert into community_decos (artist_id, name, path) values ($1, 'Two', 'a/two.png') returning id`, [old])).id;
  await h.as(art);
  await h.fails('a non-staff member cannot approve', `select public.review_community_deco('${d2}', 'approved')`);
  await h.admin();
  await h.db.query(`select set_config('request.jwt.claims', '', false)`);
}
