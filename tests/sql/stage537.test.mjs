// 537: Yapin' Management (flag management, per user). Starts from stage 24 with stand-ins for the live pieces; the
// patched functions carry the live anchor lines from Oct 26 (pg_get_functiondef), trimmed to what the checks need.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '537_management_role.sql'), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export const STANDINS = `
alter table public.profiles add column if not exists badges text[] default '{}';
alter table public.profiles add column if not exists shown_badge text;
alter table public.member_roles add column if not exists manual boolean not null default false;
create table if not exists public.site_admins (user_id uuid primary key);
create table if not exists public.site_moderators (user_id uuid primary key, added_by uuid, created_at timestamptz default now(),
  suspended_at timestamptz, suspended_reason text, head boolean not null default false);
create table if not exists public.site_developers (user_id uuid primary key, added_by uuid, created_at timestamptz default now());
create table if not exists public.site_community_managers (user_id uuid primary key, added_by uuid, created_at timestamptz default now());
create table if not exists public.site_bans (user_id uuid primary key, reason text, banned_by uuid, created_at timestamptz default now(), expires_at timestamptz);
alter table public.site_bans add column if not exists banned_by uuid;
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
create table if not exists public.creator_applications (id uuid primary key default gen_random_uuid(), user_id uuid, status text not null default 'pending');
create table if not exists public.creator_content (id uuid primary key default gen_random_uuid(), user_id uuid, status text not null default 'pending');
alter table public.creator_applications enable row level security;
alter table public.creator_content enable row level security;
alter table public.site_developers enable row level security;
alter table public.site_community_managers enable row level security;
create or replace function public.staff_mfa_ok() returns boolean language sql stable as $$ select true $$;
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$ select public.is_site_admin() or public.is_site_mod() $$;
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null) $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())) $$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $f$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout', 'takedown', 'purge') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action when 'ban' then 80 when 'badge' then 10 else 60 end;
  logged := array[action];
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then raise exception 'hourly limit'; end if;
end; $f$;
create policy "own creator applications" on public.creator_applications for select using (user_id = (select auth.uid()) or is_site_admin());
create policy "own creator content" on public.creator_content for select using (user_id = (select auth.uid()) or is_site_admin());
create policy "admins see developers" on public.site_developers for select using ((select is_site_admin()) or user_id = (select auth.uid()));
create policy "admins see community managers" on public.site_community_managers for select using ((select is_site_admin()) or user_id = (select auth.uid()));

create or replace function public.admin_suspend_moderator(uid uuid, why text default '') returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare n int;
begin
  perform public.head_mod_may_change(uid);
  update public.site_moderators set suspended_at = now(), suspended_reason = nullif(left(why, 200), '') where user_id = uid and suspended_at is null;
  get diagnostics n = row_count;
  if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_suspended', uid, left(why, 300)); end if;
end;
$function$;
create or replace function public.admin_set_developer(uid uuid, on_off boolean, note text default '') returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    insert into public.site_developers (user_id, added_by) values (uid, auth.uid()) on conflict (user_id) do nothing;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'dev_added', uid, left(note, 300));
  end if;
end;
$function$;
create or replace function public.admin_set_community_manager(uid uuid, on_off boolean, note text default '') returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    execute 'de' || 'lete from public.site_moderators where user_id = $1' using uid;
    insert into public.site_community_managers (user_id, added_by) values (uid, auth.uid()) on conflict (user_id) do nothing;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'cm_added', uid, left(note, 300));
  end if;
end;
$function$;
create or replace function public.admin_set_badge(uid uuid, badge text, on_off boolean) returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if badge is null or on_off is null then raise exception 'Unknown badge'; end if;
  if not (public.is_site_admin()
          or (public.is_site_mod() and badge = 'bug_hunter')
          or (badge = 'artist' and public.feature_on('head_mod_badges', null) and public.is_head_mod())) then
    raise exception 'Admins only';
  end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff', 'developer', 'community_manager', 'creator_1', 'creator_2', 'creator_3', 'artist') then
    raise exception 'Unknown badge';
  end if;
  perform public.mod_guard('badge', uid, null);
  if on_off then
    update public.profiles set badges = array(select distinct unnest(coalesce(badges, '{}'::text[]) || badge)) where id = uid;
  else
    update public.profiles set badges = array_remove(badges, badge) where id = uid;
  end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;
create or replace function public.site_ban(uid uuid, why text default '', wipe boolean default false) returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if uid = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;
  insert into public.site_bans (user_id, reason, banned_by) values (uid, left(coalesce(why, ''), 500), auth.uid())
  on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, expires_at = null;
end;
$function$;
create or replace function public.site_unban(uid uuid) returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare b public.site_bans;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Moderators only'; end if;
  select * into b from public.site_bans where user_id = uid;
  if b.user_id is null then return; end if;
  if not public.is_site_admin() then
    if b.banned_by is not null and b.expires_at is null then raise exception 'Only an admin can lift a confirmed ban'; end if;
    perform public.mod_guard('unban', uid, null);
  end if;
  update public.site_bans set expires_at = now() where user_id = uid;
end; $function$;
create or replace function public.review_creator(rid uuid, approve boolean, p_tier integer default null, p_note text default '') returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare r public.creator_applications;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select * into r from public.creator_applications where id = rid for update;
  if r.user_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  update public.creator_applications set status = case when approve then 'approved' else 'rejected' end where id = rid;
end; $function$;
create or replace function public.review_creator_content(cid uuid, approve boolean, p_note text default '', p_views integer default null, p_format text default null, p_checks jsonb default null) returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.creator_content set status = case when approve then 'approved' else 'rejected' end where id = cid;
end; $function$;
create or replace function public.revoke_creator(uid uuid, p_note text default '') returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.profiles set badges = array_remove(badges, 'creator_1') where id = uid;
end; $function$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`537 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.q(`insert into feature_flags (key, label, mode) values ('head_mods', 'Head mods', 'everyone'), ('head_mod_badges', 'x', 'everyone') on conflict (key) do nothing`);
  await h.ok('537 runs', () => h.db.exec(MIG));
  await h.ok('537 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'management'`)).mode, 'test');
  h.eq('patches went in once', (await h.one(`select (length(prosrc) - length(replace(prosrc, 'manager_guard', ''))) / length('manager_guard') n from pg_proc where proname = 'admin_set_badge'`)).n, 1);

  const admin = await h.signup('admin@test.dev', 'boss');
  const mgr = await h.signup('mgr@test.dev', 'manager');
  const mgr2 = await h.signup('mgr2@test.dev', 'manager2');
  const head = await h.signup('head@test.dev', 'headmod');
  const mod = await h.signup('mod@test.dev', 'modder');
  const u = await h.signup('u@test.dev', 'someone');
  const u2 = await h.signup('u2@test.dev', 'someone2');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'management'`, [admin]); // stands in for Antic
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, false)`, [head, mod]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const badges = async (uid) => (await h.one(`select badges from profiles where id = $1`, [uid])).badges;
  const amManager = async (uid) => { await h.as(uid); const r = (await h.one(`select is_site_manager() m`)).m; await h.admin(); return r; };

  // Only admins give Management, and only with the flag on for them.
  await h.as(head);
  h.eq('head mod cannot give Management', await err(`select admin_set_manager($1, true)`, [u]), 'Admins only');
  await h.as(admin);
  await h.ok('admin gives Management', () => h.q(`select admin_set_manager($1, true, 'trusted')`, [mgr]));
  await h.ok('admin gives Management to a second person', () => h.q(`select admin_set_manager($1, true)`, [mgr2]));
  h.eq('admins cannot be made managers', await err(`select admin_set_manager($1, true)`, [admin]), 'Admins don\'t need the role');
  await h.admin();
  h.eq('manager is an unpaused head mod', await h.one(`select head, suspended_at from site_moderators where user_id = $1`, [mgr]), { head: true, suspended_at: null });
  h.eq('management badge given', (await badges(mgr)).includes('management'), true);
  h.eq('logged', (await h.one(`select count(*)::int n from mod_log where action = 'manager_added'`)).n, 2);

  // The flag is per user: off for the manager, they are just a head mod.
  h.eq('flag off for them: not a manager', await amManager(mgr), false);
  await h.as(mgr);
  h.eq('flag off: cannot change a head mod', await err(`select admin_set_moderator($1, false)`, [head]), 'Only admins can change head mods');
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'management'`, [mgr]);
  h.eq('flag on: manager', await amManager(mgr), true);
  h.eq('plain head mod is not a manager', await amManager(head), false);

  // Staff changes.
  await h.as(mgr);
  await h.ok('manager adds a mod', () => h.q(`select admin_set_moderator($1, true)`, [u]));
  await h.ok('manager makes a head mod', () => h.q(`select admin_set_head_mod($1, true)`, [u]));
  await h.ok('manager unmakes a head mod', () => h.q(`select admin_set_head_mod($1, false)`, [head]));
  await h.ok('manager re-makes them', () => h.q(`select admin_set_head_mod($1, true)`, [head]));
  await h.as(admin);
  await h.ok('admin unmakes them', () => h.q(`select admin_set_head_mod($1, false)`, [head]));
  await h.as(mgr);
  h.eq('manager cannot undo an admin un-heading', await err(`select admin_set_head_mod($1, true)`, [head]), 'An admin took head mod off them. Ask an admin');
  await h.ok('manager pauses a mod', () => h.q(`select admin_suspend_moderator($1, 'checking')`, [mod]));
  await h.ok('manager removes a mod', () => h.q(`select admin_set_moderator($1, false)`, [u]));
  await h.ok('manager sets a developer', () => h.q(`select admin_set_developer($1, true)`, [u2]));
  h.eq('manager cannot change themselves', await err(`select admin_set_head_mod($1, false)`, [mgr]), 'You can\'t change your own account');
  h.eq('manager cannot change another manager', await err(`select admin_set_moderator($1, false)`, [mgr2]), 'Only an admin can change Management');
  h.eq('manager cannot change an admin', await err(`select admin_set_developer($1, true)`, [admin]), 'Admins can\'t be changed');
  h.eq('manager cannot give Management', await err(`select admin_set_manager($1, true)`, [u2]), 'Admins only');
  h.eq('manager sees developers', (await h.one(`select count(*)::int n from site_developers`)).n, 1);
  h.eq('manager sees managers', (await h.one(`select count(*)::int n from site_managers`)).n, 2);

  // A head mod can't touch a manager or undo a manager's removal.
  await h.admin();
  await h.q(`update site_moderators set head = true where user_id = $1`, [head]);
  await h.q(`update site_moderators set suspended_at = null where user_id = $1`, [mod]);
  await h.as(head);
  h.eq('head mod cannot remove a manager', await err(`select admin_set_moderator($1, false)`, [mgr]), 'Only admins can change head mods');
  h.eq('head mod cannot undo a manager\'s removal', await err(`select admin_set_moderator($1, true)`, [u]), 'Someone above you took them off. Ask them');
  await h.as(mod);
  h.eq('plain mod cannot ban a manager', await err(`select mod_guard('ban', $1, 'because reasons')`, [mgr]), 'You can\'t moderate an admin or another moderator');

  // Daily cap for staff changes.
  await h.admin();
  await h.q(`insert into mod_log (actor, action, target_id) select $1, 'mod_added', $2 from generate_series(1, 25)`, [mgr, u]);
  await h.as(mgr);
  h.eq('25 staff changes a day', await err(`select admin_set_developer($1, true)`, [u]), 'That\'s 25 staff changes today. Ask an admin for more');
  await h.admin();
  await h.q(`update mod_log set created_at = now() - interval '2 days' where actor = $1`, [mgr]);

  // Badges.
  await h.as(mgr);
  await h.ok('manager gives partner', () => h.q(`select admin_set_badge($1, 'partner', true)`, [u]));
  await h.ok('manager gives a head mod a badge', () => h.q(`select admin_set_badge($1, 'artist', true)`, [head]));
  h.eq('manager cannot give staff', await err(`select admin_set_badge($1, 'staff', true)`, [u]), 'Admins only');
  h.eq('manager cannot give the developer badge', await err(`select admin_set_badge($1, 'developer', true)`, [u]), 'Admins only');
  h.eq('manager cannot badge themselves', await err(`select admin_set_badge($1, 'partner', true)`, [mgr]), 'You can\'t change your own account');
  h.eq('manager cannot badge an admin', await err(`select admin_set_badge($1, 'partner', true)`, [admin]), 'Admins can\'t be changed');
  await h.admin();
  h.eq('partner given', (await badges(u)).includes('partner'), true);
  await h.q(`insert into mod_log (actor, action, target_id) select $1, 'badge_given', $2 from generate_series(1, 30)`, [mgr, u]);
  await h.as(mgr);
  h.eq('30 badges an hour', await err(`select admin_set_badge($1, 'early', true)`, [u]), 'That\'s 30 badges this hour. Wait a bit or ask an admin');
  await h.as(head);
  h.eq('head mod still only artist', await err(`select admin_set_badge($1, 'partner', true)`, [u2]), 'Admins only');

  // Bans.
  await h.as(mgr);
  h.eq('manager ban needs a reason', await err(`select site_ban($1, 'no')`, [u2]), 'Give a reason (at least 5 characters)');
  h.eq('manager cannot wipe', await err(`select site_ban($1, 'spam bot account', true)`, [u2]), 'Only an admin can ban and delete their messages');
  h.eq('manager cannot ban staff', await err(`select site_ban($1, 'bad mod here')`, [head]), 'You can\'t moderate an admin or another moderator');
  await h.ok('manager bans permanently', () => h.q(`select site_ban($1, 'spam bot account')`, [u2]));
  await h.ok('manager lifts their own confirmed ban', () => h.q(`select site_unban($1)`, [u2]));
  await h.as(admin);
  await h.ok('admin bans', () => h.q(`select site_ban($1, 'admin call')`, [u2]));
  await h.as(mgr);
  h.eq('manager cannot lift an admin\'s ban', await err(`select site_unban($1)`, [u2]), 'Only an admin can lift a confirmed ban');
  h.eq('manager cannot re-ban over an admin ban', await err(`select site_ban($1, 'taking this over')`, [u2]), 'An admin banned them. Ask an admin');

  // Creator Program.
  await h.admin();
  const app = (await h.one(`insert into creator_applications (user_id) values ($1) returning id`, [u])).id;
  const own = (await h.one(`insert into creator_content (user_id) values ($1) returning id`, [mgr])).id;
  const theirs = (await h.one(`insert into creator_content (user_id) values ($1) returning id`, [u])).id;
  await h.as(mgr);
  h.eq('manager reads applications', (await h.one(`select count(*)::int n from creator_applications`)).n, 1);
  await h.ok('manager reviews an application', () => h.q(`select review_creator($1, true, 1)`, [app]));
  await h.ok('manager reviews content', () => h.q(`select review_creator_content($1, true)`, [theirs]));
  h.eq('manager cannot review their own content', await err(`select review_creator_content($1, true)`, [own]), 'You can\'t change your own account');
  h.eq('manager cannot revoke themselves', await err(`select revoke_creator($1)`, [mgr]), 'You can\'t change your own account');
  await h.admin();
  const other = (await h.one(`insert into creator_content (user_id) values ($1) returning id`, [mgr2])).id;
  await h.as(mgr);
  h.eq('manager cannot approve another manager', await err(`select review_creator_content($1, true)`, [other]), 'Only an admin can change Management');
  await h.admin();
  await h.q(`insert into mod_log (actor, action, target_id) select $1, 'content_approved', $2 from generate_series(1, 10)`, [mgr, u]);
  const more = (await h.one(`insert into creator_content (user_id) values ($1) returning id`, [u])).id;
  await h.as(mgr);
  h.eq('10 creator approvals a day', await err(`select review_creator_content($1, true)`, [more]), 'That\'s 10 Creator approvals today. Ask an admin for more');
  await h.ok('manager revokes someone', () => h.q(`select revoke_creator($1)`, [u]));
  await h.as(head);
  h.eq('head mod cannot review creators', await err(`select review_creator($1, false)`, [app]), 'Admins only');
  h.eq('head mod reads no applications', (await h.one(`select count(*)::int n from creator_applications`)).n, 0);

  // Plain users see nothing; managers can't be taken off by anyone but an admin.
  await h.as(u2);
  h.eq('plain user sees no managers', (await h.one(`select count(*)::int n from site_managers`)).n, 0);
  await h.fails('plain user cannot write managers', `insert into site_managers (user_id) values ($1)`, [u2]);
  await h.as(admin);
  h.eq('admin must take Management off first', await err(`select admin_set_moderator($1, false)`, [mgr]), 'Take Management off first');
  await h.ok('admin pauses a manager as mod', () => h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [mgr]));
  h.eq('paused manager is not a manager', await amManager(mgr), false);
  h.eq('paused manager loses the badge', (await badges(mgr)).includes('management'), false);
  await h.admin();
  await h.q(`update site_moderators set suspended_at = null where user_id = $1`, [mgr]);
  h.eq('unpaused: badge back', (await badges(mgr)).includes('management'), true);
  await h.as(admin);
  await h.ok('admin takes Management off', () => h.q(`select admin_set_manager($1, false, 'done')`, [mgr]));
  await h.admin();
  h.eq('badge gone, still a head mod', [(await badges(mgr)).includes('management'), (await h.one(`select head from site_moderators where user_id = $1`, [mgr])).head], [false, true]);
  h.eq('removal logged', (await h.one(`select count(*)::int n from mod_log where action = 'manager_removed'`)).n, 1);
}
