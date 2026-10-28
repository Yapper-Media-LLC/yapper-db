// 565: mod burst guard (flag mod_burst_guard). Base schema plus the flags tables (031, 041) and stand-ins for the
// staff tables, the staff helpers (no MFA), mod_log, community_decos, site_bans.expires_at, and trimmed copies of the
// live RPCs the migration patches at their staff check (review_community_deco, staff_lift_suspension,
// admin_verify_bot), so the anchor patching is checked here too.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '565_mod_burst_guard.sql'), 'utf8');

const STANDINS = String.raw`
create table if not exists public.site_moderators (user_id uuid primary key, added_by uuid, created_at timestamptz default now(),
  suspended_at timestamptz, suspended_reason text, head boolean not null default false);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid, message_id uuid, reason text, created_at timestamptz not null default now());
create index if not exists mod_log_actor_idx on public.mod_log (actor, created_at desc);
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.community_decos (id uuid primary key default gen_random_uuid(), name text not null default 'x', artist_id uuid, path text,
  status text not null default 'pending', review_note text, reviewed_by uuid, reviewed_at timestamptz, created_at timestamptz not null default now());
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$ select public.is_site_admin() or public.is_site_mod() $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid) $$;
create or replace function public.can_review_bots() returns boolean language sql stable security definer set search_path = public as $$ select public.is_staff() $$;
-- The live RPCs, trimmed to their staff check, the write and the log line (the anchors are the live text).
create or replace function public.review_community_deco(p_id uuid, p_status text, p_note text default '') returns void language plpgsql security definer set search_path = public as $$
declare d public.community_decos;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  select * into d from public.community_decos where id = p_id for update;
  update public.community_decos set status = p_status, review_note = p_note, reviewed_by = (select auth.uid()), reviewed_at = now() where id = p_id;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'deco_' || p_status, d.artist_id, p_note);
end; $$;
create or replace function public.staff_lift_suspension(uid uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'suspension_lifted', uid, 'Suspension lifted');
end $$;
create or replace function public.admin_verify_bot(bid uuid, ok boolean, note text default null, was_private boolean default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_review_bots() then raise exception 'Moderators only'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when ok then 'bot_verified' else 'bot_rejected' end, bid, coalesce(note, ''));
end $$;
`;

export default async function (h) {
  for (const bad of ['drop ', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`565 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('565 runs', () => h.db.exec(MIG));
  await h.ok('565 re-runs cleanly', () => h.db.exec(MIG));

  h.eq('flag row: test mode, Antic only', await h.one(`select mode, users::text[] as users from feature_flags where key = 'mod_burst_guard'`),
    { mode: 'test', users: ['00000000-0000-4000-8000-00000000a001'] });
  for (const fn of ['review_community_deco', 'staff_lift_suspension', 'admin_verify_bot']) {
    const d = (await h.one(`select pg_get_functiondef(p.oid) as d from pg_proc p where proname = $1`, [fn])).d;
    h.eq(`${fn} calls mod_guard exactly once after its staff check`, d.split('mod_guard(').length - 1, 1);
  }
  await h.fails('a changed anchor stops the patch', `select pg_temp.patch_fn('public.staff_lift_suspension(uuid)', 'no-such-marker', 'not in there', 'x')`);
  h.eq('the trigger is on community_decos', (await h.q(`select 1 from pg_trigger where tgname = 'community_decos_takedown_guard'`)).length, 1);
  h.eq('and on site_bans', (await h.q(`select 1 from pg_trigger where tgname = 'site_bans_unban_guard'`)).length, 1);

  const u = {};
  for (const n of ['admin', 'mod', 'mod2', 'mod3', 'mod4', 'mod5', 'artist', 'banned', 'target']) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [u.admin]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2), ($3), ($4), ($5)`, [u.mod, u.mod2, u.mod3, u.mod4, u.mod5]);
  // Log rows for a mod, ages in minutes ago. Spread over actions so no per-action cap gets in the way.
  const fill = async (who, count, minutesAgo) => {
    await h.admin();
    await h.q(`insert into mod_log (actor, action, created_at) select $1, 'act_' || (g % 7), now() - make_interval(mins => $3) - (g || ' seconds')::interval from generate_series(1, $2) g`, [who, count, minutesAgo]);
  };
  const guard = async (who, action, target = null, why = 'because reasons') => {
    await h.as(who);
    try { await h.q(`select mod_guard($1, $2, $3)`, [action, target, why]); await h.admin(); return 'ok'; }
    catch (e) { await h.admin(); return e.message; }
  };
  const paused = async (who) => (await h.one(`select suspended_at is not null as p, suspended_reason as r from site_moderators where user_id = $1`, [who]));

  // ---------- flag off: today's behaviour ----------
  await fill(u.mod, 70, 1);
  h.eq('flag off (mod not in the test list): 70 actions in a minute trip nothing', await guard(u.mod, 'ban', u.target), 'ok');
  h.eq('and the mod is not paused', (await paused(u.mod)).p, false);

  // ---------- flag on ----------
  await h.q(`update feature_flags set mode = 'everyone' where key = 'mod_burst_guard'`);
  h.eq('flag on: over 60 in 10 minutes is refused', (await guard(u.mod, 'ban', u.target)).startsWith('Slow down'), true);
  h.eq('an admin is never counted', await guard(u.admin, 'ban', u.target), 'ok');

  await fill(u.mod2, 59, 2);
  h.eq('the 60th action in 10 minutes still goes through', await guard(u.mod2, 'ban', u.target), 'ok');
  h.eq('but it pauses the mod', await paused(u.mod2), { p: true, r: 'Automatic: 60 actions in 10 minutes' });
  h.eq('and logs it', (await h.q(`select 1 from mod_log where actor = $1 and action = 'auto_suspended'`, [u.mod2])).length, 1);
  h.eq('the next action is refused as paused', (await guard(u.mod2, 'timeout', u.target)).startsWith('Your moderator powers are paused'), true);
  await h.q(`update site_moderators set suspended_at = null, suspended_reason = null where user_id = $1`, [u.mod2]);
  h.eq('an admin lifts it and the budget restarts from the pause', await guard(u.mod2, 'timeout', u.target), 'ok');

  await fill(u.mod3, 199, 30);
  h.eq('199 in the hour, none in the last 10 minutes: the 200th goes through', await guard(u.mod3, 'ban', u.target), 'ok');
  h.eq('and pauses the mod for the hour', (await paused(u.mod3)).r, 'Automatic: 200 actions in an hour');

  // ---------- the patched RPCs and the per-action caps ----------
  const deco = async (status = 'approved') => { await h.admin(); return (await h.one(`insert into community_decos (artist_id, status, path) values ($1, $2, gen_random_uuid()::text) returning id`, [u.artist, status])).id; };
  const review = async (who, id, status) => { await h.as(who); try { await h.q(`select review_community_deco($1, $2, 'nope')`, [id, status]); await h.admin(); return 'ok'; } catch (e) { await h.admin(); return e.message; } };
  for (let i = 0; i < 10; i++) h.eq(`takedown ${i + 1} of 10 is fine`, await review(u.mod4, await deco(), 'removed'), 'ok');
  h.eq('the 11th takedown in an hour is refused by the RPC', (await review(u.mod4, await deco(), 'removed')).includes('10 an hour'), true);
  h.eq('approvals have their own, bigger cap', await review(u.mod4, await deco('pending'), 'approved'), 'ok');
  h.eq('admins have no cap', await review(u.admin, await deco(), 'removed'), 'ok');

  // The table refuses a takedown too, with no RPC in the way (a definer path: jwt set, no role switch).
  const direct = async (who, id) => {
    await h.admin(); await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [who]);
    try { await h.q(`update community_decos set status = 'removed', reviewed_by = $2, reviewed_at = now() where id = $1`, [id, who]); await h.admin(); return 'ok'; }
    catch (e) { await h.admin(); return e.message; }
  };
  h.eq('community_decos itself refuses the 11th takedown', (await direct(u.mod4, await deco())).includes('10 decorations'), true);
  h.eq('a paused mod is refused at the table', (await direct(u.mod3, await deco())).startsWith('Your moderator powers'), true);
  await h.q(`select set_config('request.jwt.claim.sub', '', false)`);
  const d0 = await deco();
  await h.q(`update community_decos set status = 'removed' where id = $1`, [d0]);
  h.eq('no signed-in user (service role, dashboard) passes', (await h.one(`select status from community_decos where id = $1`, [d0])).status, 'removed');

  await h.as(u.mod);
  await h.fails('staff_lift_suspension is guarded now (mod over budget)', `select staff_lift_suspension($1)`, [u.target]);
  await h.admin();
  await h.as(u.mod2);
  await h.q(`select admin_verify_bot(gen_random_uuid(), true, 'fine')`);
  await h.admin();
  h.eq('admin_verify_bot logs through the guard', (await h.q(`select 1 from mod_log where actor = $1 and action = 'bot_verified'`, [u.mod2])).length, 1);

  // The pause has to survive a statement where mod_guard pauses and the table trigger then asks again (must-fix from review).
  await fill(u.mod5, 59, 2);
  const dz = await deco();
  h.eq('the 60th action through an RPC with a table trigger still goes through', await review(u.mod5, dz, 'removed'), 'ok');
  h.eq('the deco is taken down', (await h.one(`select status from community_decos where id = $1`, [dz])).status, 'removed');
  h.eq('and the mod is paused', (await paused(u.mod5)).p, true);
  // The RPC's own staff check runs before mod_guard, so a paused mod sees the same 'Staff only' a manually paused mod does.
  h.eq('the next takedown is refused', await review(u.mod5, await deco(), 'removed'), 'Staff only');

  // ---------- site_bans: the unban cap at the table ----------
  const unban = async (who) => {
    await h.admin(); await h.q(`insert into site_bans (user_id, reason) values ($1, 'x') on conflict (user_id) do update set expires_at = null`, [u.banned]);
    await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [who]);
    try { await h.q(`update site_bans set expires_at = now() where user_id = $1`, [u.banned]); await h.admin(); return 'ok'; }
    catch (e) { await h.admin(); return e.message; }
  };
  h.eq('a mod under the cap lifts a ban', await unban(u.mod2), 'ok');
  await h.q(`insert into mod_log (actor, action, created_at) select $1, 'unban', now() - interval '20 minutes' - (g || ' seconds')::interval from generate_series(1, 60) g`, [u.mod4]);
  h.eq('60 unbans in the hour (older than the 10-minute window): the table refuses the next', (await unban(u.mod4)).includes('60 bans'), true);
  h.eq('admins pass', await unban(u.admin), 'ok');
  await h.q(`update feature_flags set mode = 'off' where key = 'mod_burst_guard'`);
  h.eq('flag off: the table guard stands down', await unban(u.mod4), 'ok');
  h.eq('and so does the deco guard', await direct(u.mod4, await deco()), 'ok');
  await h.q(`update feature_flags set mode = 'everyone' where key = 'mod_burst_guard'`);
}
