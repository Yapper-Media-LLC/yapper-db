// 648: Management can ban for good. Starts from stage 24 with 537's stand-ins, 537 itself, then the live text of
// site_ban (Oct 28, pg_get_functiondef) with stubs for the pieces PGlite doesn't have, then 648.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const MIG537 = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '537_management_role.sql'), 'utf8');
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '648_managers_permaban.sql'), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

// What site_ban (live, after 537) and mod_ban_with_proof (242) lean on.
const LIVE = `
alter table public.site_bans add column if not exists proof jsonb;
create table if not exists public.app_settings (id int primary key default 1);
alter table public.app_settings add column if not exists webhook_user_id uuid;
create or replace function public.is_frozen(uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.require_staff_reauth() returns void language sql as $$ select null::void $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$ select true $$;
create or replace function public.standing_proof_build(uid uuid, rid uuid, with_message boolean, note text, images text[])
returns jsonb language sql stable as $$ select case when note is null then null else jsonb_build_object('note', note) end $$;
create or replace function public.mod_ban(uid uuid, why text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.mod_guard('ban', uid, why);
  insert into public.site_bans (user_id, reason, banned_by, expires_at)
  values (uid, left(why, 500), auth.uid(), case when public.is_site_admin() then null else now() + interval '7 days' end)
  on conflict (user_id) do update
    set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now(), expires_at = excluded.expires_at
    where site_bans.expires_at <= now() or excluded.expires_at is null
       or (site_bans.expires_at is not null and excluded.expires_at >= site_bans.expires_at);
  if not found then raise exception 'Already banned for longer'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'ban', uid, left(why, 300));
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now() where target_id = uid and status = 'open';
end;
$$;
create or replace function public.mod_ban_with_proof(uid uuid, why text, wipe boolean default false, rid uuid default null,
  with_message boolean default true, note text default null, images text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare pr jsonb;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  if not public.feature_on_for_me('standing_proof') then raise exception 'Proof isn''t on for you yet'; end if;
  pr := public.standing_proof_build(uid, rid, with_message, note, images);
  if public.is_site_admin() then
    perform public.site_ban(uid, why, coalesce(wipe, false));
  else
    if coalesce(wipe, false) then raise exception 'Only an admin can delete all their messages'; end if;
    perform public.mod_ban(uid, why);
  end if;
  if pr is not null then
    update public.site_bans set proof = pr where user_id = uid and created_at = now();
  end if;
end $$;
grant execute on function public.mod_ban_with_proof(uuid, text, boolean, uuid, boolean, text, text[]) to authenticated;
CREATE OR REPLACE FUNCTION public.site_ban(uid uuid, why text DEFAULT ''::text, wipe boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_site_admin() then
    if not public.is_site_manager() then raise exception 'Admins only'; end if;
    if wipe then raise exception 'Only an admin can ban and delete their messages'; end if;
    if exists (select 1 from public.site_bans sb join public.site_admins sa on sa.user_id = sb.banned_by where sb.user_id = uid and (sb.expires_at is null or sb.expires_at > now())) then raise exception 'An admin banned them. Ask an admin'; end if;
    perform public.mod_guard('ban', uid, why);
  end if;
  if uid = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;
  if uid = (select a.webhook_user_id from public.app_settings a limit 1) then
    raise exception 'That''s the shared webhook account. Ban whoever made the webhook instead.';
  end if;
  insert into public.site_bans (user_id, reason, banned_by) values (uid, left(coalesce(why, ''), 500), auth.uid())
  on conflict (user_id) do update
    set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now(), expires_at = excluded.expires_at
    -- 157: a lifted (expired) ban is replaced; a running one only by a ban at least as long (null = permanent).
    where site_bans.expires_at <= now() or excluded.expires_at is null
       or (site_bans.expires_at is not null and excluded.expires_at >= site_bans.expires_at);
  if wipe and public.is_frozen(uid) then raise exception 'This account is frozen to keep evidence: ban it without deleting messages'; end if;
  if wipe then
    perform public.require_staff_reauth();
    delete from public.messages where author_id = uid;
  end if;
  -- Close their open reports as handled.
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now()
   where target_id = uid and status = 'open';
end;
$function$;
grant execute on function public.site_ban(uuid, text, boolean) to authenticated;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`648 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.q(`insert into feature_flags (key, label, mode) values ('head_mods', 'Head mods', 'everyone'), ('head_mod_badges', 'x', 'everyone') on conflict (key) do nothing`);
  await h.db.exec(MIG537);
  await h.db.exec(LIVE);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'management'`); // live since Oct 27
  await h.ok('648 runs', () => h.db.exec(MIG));
  await h.ok('648 re-runs cleanly', () => h.db.exec(MIG));
  const src = (await h.one(`select prosrc from pg_proc where proname = 'site_ban'`)).prosrc;
  h.eq('site_ban patched once: manager_guard', src.split("manager_guard('ban'").length - 1, 1);
  h.eq('site_ban patched once: log row', src.split("values (auth.uid(), 'ban', uid").length - 1, 1);
  h.eq('one mod_ban_with_proof left', (await h.one(`select count(*)::int n from pg_proc where proname = 'mod_ban_with_proof'`)).n, 1);
  h.eq('it takes forever', (await h.one(`select pg_get_function_arguments(oid) a from pg_proc where proname = 'mod_ban_with_proof'`)).a.includes('forever boolean DEFAULT false'), true);

  const admin = await h.signup('admin@test.dev', 'boss');
  const mgr = await h.signup('mgr@test.dev', 'manager');
  const head = await h.signup('head@test.dev', 'headmod');
  const mod = await h.signup('mod@test.dev', 'modder');
  const u1 = await h.signup('u1@test.dev', 'one');
  const u2 = await h.signup('u2@test.dev', 'two');
  const u3 = await h.signup('u3@test.dev', 'three');
  const u4 = await h.signup('u4@test.dev', 'four');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, false)`, [head, mod]);
  await h.as(admin);
  await h.q(`select admin_set_manager($1, true, 'trusted')`, [mgr]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const ban = (uid) => h.one(`select banned_by, expires_at, proof from site_bans where user_id = $1`, [uid]);
  const logged = (actor, uid) => h.one(`select count(*)::int n from mod_log where actor = $1 and target_id = $2 and action = 'ban'`, [actor, uid]);

  // The plain path (no proof): a manager's site_ban is permanent and logged.
  await h.as(mgr);
  h.eq('manager needs a reason', await err(`select site_ban($1, 'no')`, [u1]), 'Give a reason (at least 5 characters)');
  h.eq('manager cannot wipe', await err(`select site_ban($1, 'spam bot account', true)`, [u1]), 'Only an admin can ban and delete their messages');
  h.eq('manager cannot ban staff', await err(`select site_ban($1, 'bad mod here')`, [mod]), 'You can\'t moderate an admin or another moderator');
  h.eq('manager cannot ban themselves', await err(`select site_ban($1, 'oops wrong tab')`, [mgr]), 'You can\'t moderate an admin or another moderator');
  await h.ok('manager bans for good', () => h.q(`select site_ban($1, 'spam bot account')`, [u1]));
  await h.admin();
  h.eq('no expiry', (await ban(u1)).expires_at, null);
  h.eq('banned_by is the manager', (await ban(u1)).banned_by, mgr);
  h.eq('logged as ban', (await logged(mgr, u1)).n, 1);
  h.eq('reason in the log', (await h.one(`select reason from mod_log where actor = $1 and target_id = $2 and action = 'ban'`, [mgr, u1])).reason, 'spam bot account');

  // With proof (flag standing_proof): forever = permanent through site_ban, the proof stays on the row.
  await h.as(mgr);
  await h.ok('manager bans for good with proof', () => h.q(`select mod_ban_with_proof($1, 'scam links everywhere', false, null, true, 'see screenshot', null, true)`, [u2]));
  await h.admin();
  h.eq('permanent', (await ban(u2)).expires_at, null);
  h.eq('proof kept', (await ban(u2)).proof, { note: 'see screenshot' });
  h.eq('logged once', (await logged(mgr, u2)).n, 1);
  await h.as(mgr);
  await h.ok('manager can still pick 7 days', () => h.q(`select mod_ban_with_proof($1, 'spam, give them a week', false, null, true, null, null, false)`, [u3]));
  await h.admin();
  h.eq('7 days when they say so', (await ban(u3)).expires_at !== null, true);
  h.eq('a 7-day ban logs too', (await logged(mgr, u3)).n, 1);

  // A manager lifts their own permanent ban; nobody below them gets the permanent path.
  await h.as(mgr);
  await h.ok('manager lifts their permanent ban', () => h.q(`select site_unban($1)`, [u1]));
  await h.as(head);
  h.eq('head mod: site_ban still admins only', await err(`select site_ban($1, 'trying it on')`, [u4]), 'Admins only');
  h.eq('head mod: no forever with proof', await err(`select mod_ban_with_proof($1, 'trying it on', false, null, true, null, null, true)`, [u4]), 'Only an admin or Management can ban for good');
  await h.as(mod);
  h.eq('mod: no forever with proof', await err(`select mod_ban_with_proof($1, 'trying it on', false, null, true, null, null, true)`, [u4]), 'Only an admin or Management can ban for good');
  await h.ok('mod: 7 days with proof as before', () => h.q(`select mod_ban_with_proof($1, 'spamming a lot', false, null, true, 'proof', null)`, [u4]));
  await h.admin();
  h.eq('mod ban still expires', (await ban(u4)).expires_at !== null, true);
  h.eq('head mod and mod logged nothing extra', (await h.one(`select count(*)::int n from mod_log where action = 'ban' and actor in ($1, $2)`, [head, mod])).n, 1);

  // Admin bans are unchanged: permanent, no mod_log row (as before 648), and a manager can't re-ban over one.
  await h.as(admin);
  await h.ok('admin bans', () => h.q(`select site_ban($1, 'admin call')`, [u1]));
  await h.admin();
  h.eq('admin ban not logged (unchanged)', (await logged(admin, u1)).n, 0);
  await h.as(mgr);
  h.eq('manager cannot re-ban over an admin ban', await err(`select site_ban($1, 'taking this over')`, [u1]), 'An admin banned them. Ask an admin');
  h.eq('nor with proof', await err(`select mod_ban_with_proof($1, 'taking this over', false, null, true, null, null, true)`, [u1]), 'An admin banned them. Ask an admin');

  // 25 bans a day, counting every 'ban' row of theirs (so the 7-day one above counts too).
  await h.admin();
  const soFar = (await h.one(`select count(*)::int n from mod_log where actor = $1 and action = 'ban'`, [mgr])).n;
  h.eq('three bans so far', soFar, 3);
  await h.q(`insert into mod_log (actor, action, target_id, reason) select $1, 'ban', gen_random_uuid(), 'filler' from generate_series(1, 21)`, [mgr]);
  const u5 = await h.signup('u5@test.dev', 'five');
  const u6 = await h.signup('u6@test.dev', 'six');
  await h.as(mgr);
  await h.ok('25th ban of the day goes through', () => h.q(`select site_ban($1, 'last one today')`, [u5]));
  h.eq('26th is refused', await err(`select site_ban($1, 'one too many')`, [u6]), 'That\'s 25 bans today. Ask an admin for more');
  h.eq('with proof too', await err(`select mod_ban_with_proof($1, 'one too many', false, null, true, null, null, true)`, [u6]), 'That\'s 25 bans today. Ask an admin for more');
  await h.admin();
  h.eq('refused ban left no row', (await h.one(`select count(*)::int n from site_bans where user_id = $1`, [u6])).n, 0);
  await h.q(`update mod_log set created_at = now() - interval '25 hours' where actor = $1 and reason = 'filler'`, [mgr]);
  await h.as(mgr);
  await h.ok('yesterday\'s bans don\'t count', () => h.q(`select site_ban($1, 'new day new ban')`, [u6]));
  h.eq('admins are not capped', await (async () => { await h.as(admin); return err(`select site_ban($1, 'admin again')`, [u5]); })(), 'ok');
}
