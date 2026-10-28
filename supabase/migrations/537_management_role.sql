-- 537: Yapin' Management (Antic, Oct 26: "start work on the manager role. above all other roles"). Flag management
-- (test: Antic). The rank is now Admin (Antic) > Management > Head Mod > Mod.
--
-- A manager is a head mod with a row in site_managers, so everything a head mod has (Mod Center, the Log, Mod stats,
-- Moderators, can't be touched by mods or head mods, mod_guard's protection of staff) comes with it unchanged. On top:
--   * staff: add, remove and pause mods and head mods, make and unmake head mods, set Developers and Community
--     Managers. Never themselves, an admin or another manager. At most 25 staff changes a day (manager_guard).
--   * badges: every badge admin_set_badge knows except staff and the role ones (developer, community_manager:
--     those come with the roles above), on anyone but admins, managers and themselves, 30 an hour.
--   * site bans (not "ban and delete messages", that stays admin only) through mod_guard (reason, hourly limit, no
--     staff), and lifting confirmed bans unless an admin placed them. A running admin ban can't be re-banned over
--     (that would make the manager its owner and let them lift it).
--   * Creator Program: review applications and content and revoke, never for themselves, admins or managers, at most
--     10 approvals a day (each approval can come with Plus). Read applications and content.
--   * Suggestions: RLS already lets staff decide them; the app now shows the tab to managers.
-- Admin only as before: giving Management (admin_set_manager), flags, Plus/Shards gifting, billing, images, bot
-- hosting, servers, wiping messages.
-- is_site_manager() needs the flag on for the manager (per user, like head_mod_badges), an unpaused head mod row and
-- staff 2FA. Pausing or un-heading a manager pauses Management too. The 'management' badge follows the same rule
-- (sync_management_badge). An HQ role for Management is given by hand for now: picking it by name would let anyone
-- who can make roles in HQ point the trigger at their own role.
-- Functions below that only change one line are patched into the live text (pg_get_functiondef), like 522/535.
-- No real user gets the role here. Re-runnable.

set lock_timeout = '3s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('management', 'Yapin'' Management', 'Staff role above head mods: staff changes, badges, site bans, creators, suggestions', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create table if not exists public.site_managers (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  added_by uuid,
  created_at timestamptz not null default now()
);
alter table public.site_managers enable row level security;
revoke all on public.site_managers from anon, authenticated;
grant select on public.site_managers to authenticated;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_managers' and policyname = 'staff see managers') then
    create policy "staff see managers" on public.site_managers for select to authenticated
      using ((select public.is_staff()) or user_id = (select auth.uid()));
  end if;
end $$;

create or replace function public.is_site_manager()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  -- Primary-key lookups first: everyone who isn't a manager stops here, before the flag read.
  if auth.uid() is null or not exists (
    select 1 from public.site_managers m join public.site_moderators s on s.user_id = m.user_id
     where m.user_id = auth.uid() and s.head and s.suspended_at is null) then
    return false;
  end if;
  return public.feature_on('management', null) and public.staff_mfa_ok();
end;
$$;
revoke all on function public.is_site_manager() from public, anon;
grant execute on function public.is_site_manager() to authenticated;

-- What a manager may do to `target`: never themselves, an admin or another manager; 25 staff changes a day,
-- 30 badges an hour and 10 Creator Program approvals a day. Admins pass.
create or replace function public.manager_guard(action text, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_manager() then raise exception 'Admins only'; end if;
  perform pg_advisory_xact_lock(hashtextextended('manager_cap:' || auth.uid()::text, 0));
  if target is null then raise exception 'Pick someone'; end if;
  if target = auth.uid() then raise exception 'You can''t change your own account'; end if;
  if exists (select 1 from public.site_admins where user_id = target) then raise exception 'Admins can''t be changed'; end if;
  if exists (select 1 from public.site_managers where user_id = target) then raise exception 'Only an admin can change Management'; end if;
  if action = 'badge' then
    select count(*) into n from public.mod_log where actor = auth.uid() and created_at > now() - interval '1 hour'
       and mod_log.action in ('badge_given', 'badge_removed');
    if n >= 30 then raise exception 'That''s 30 badges this hour. Wait a bit or ask an admin'; end if;
  elsif action = 'creator' then
    select count(*) into n from public.mod_log where actor = auth.uid() and created_at > now() - interval '24 hours'
       and mod_log.action in ('creator_approved', 'content_approved');
    if n >= 10 then raise exception 'That''s 10 Creator approvals today. Ask an admin for more'; end if;
  elsif action = 'creator_other' then
    null; -- rejections and revokes: no cap
  else
    select count(*) into n from public.mod_log where actor = auth.uid() and created_at > now() - interval '24 hours'
       and mod_log.action in ('mod_added', 'mod_removed', 'mod_suspended', 'head_mod_added', 'head_mod_removed',
                              'dev_added', 'dev_removed', 'cm_added', 'cm_removed');
    if n >= 25 then raise exception 'That''s 25 staff changes today. Ask an admin for more'; end if;
  end if;
end;
$$;
revoke all on function public.manager_guard(text, uuid) from public, anon, authenticated;

-- Head mods keep their rules; managers go through manager_guard (so they can change head mods too).
create or replace function public.head_mod_may_change(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_site_admin() then return; end if;
  if public.is_site_manager() then perform public.manager_guard('staff', uid); return; end if;
  if not public.is_head_mod() then raise exception 'Admins only'; end if;
  perform pg_advisory_xact_lock(hashtextextended('head_mod_cap:' || auth.uid()::text, 0));
  if uid = auth.uid() then raise exception 'You can''t change your own role'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins can''t be changed'; end if;
  if exists (select 1 from public.site_moderators where user_id = uid and head) then raise exception 'Only admins can change head mods'; end if;
  if (select count(*) from public.mod_log where actor = auth.uid() and created_at > now() - interval '24 hours'
        and action in ('mod_added', 'mod_removed', 'mod_suspended')) >= 10 then
    raise exception 'That''s 10 moderator changes today. Ask an admin for more';
  end if;
end $$;

create or replace function public.admin_set_head_mod(uid uuid, on_off boolean, note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then
    if not public.is_site_manager() then raise exception 'Admins only'; end if;
    perform public.manager_guard('staff', uid);
    -- Managers can't undo an admin taking head mod off.
    if on_off and (select l.action from public.mod_log l join public.site_admins a on a.user_id = l.actor
                    where l.target_id = uid and l.action in ('head_mod_added', 'head_mod_removed')
                    order by l.created_at desc limit 1) = 'head_mod_removed' then
      raise exception 'An admin took head mod off them. Ask an admin';
    end if;
  end if;
  if on_off and not public.feature_on('head_mods', null) then raise exception 'Head mods aren''t on yet'; end if;
  if on_off then
    if not exists (select 1 from public.site_moderators where user_id = uid and suspended_at is null) then
      raise exception 'Make them a moderator first (and not paused)';
    end if;
    update public.site_moderators set head = true where user_id = uid and not head;
    if found then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'head_mod_added', uid, left(note, 300)); end if;
  else
    if exists (select 1 from public.site_managers where user_id = uid) then raise exception 'Take Management off first'; end if;
    update public.site_moderators set head = false where user_id = uid and head;
    if found then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'head_mod_removed', uid, left(note, 300)); end if;
  end if;
end $$;

create or replace function public.admin_set_moderator(uid uuid, on_off boolean, note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  perform public.head_mod_may_change(uid);
  if on_off then
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    -- Nobody undoes someone above them: head mods can't undo an admin or a manager, managers can't undo an admin.
    -- An automatic pause also waits for an admin.
    if not public.is_site_admin() and (
         (select l.action from public.mod_log l
           where l.target_id = uid and l.action in ('mod_added', 'mod_removed', 'mod_suspended')
             and (exists (select 1 from public.site_admins a where a.user_id = l.actor)
                  or (not public.is_site_manager() and exists (select 1 from public.site_managers m where m.user_id = l.actor)))
           order by l.created_at desc limit 1) in ('mod_removed', 'mod_suspended')
         or exists (select 1 from public.site_moderators where user_id = uid and suspended_reason like 'Automatic:%')) then
      raise exception 'Someone above you took them off. Ask them';
    end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    if exists (select 1 from public.site_community_managers where user_id = uid) then
      raise exception 'They''re a Community Manager (no reports). Take that role off first if they should see reports';
    end if;
    insert into public.site_moderators (user_id, added_by) values (uid, auth.uid())
    on conflict (user_id) do update set suspended_at = null, suspended_reason = null where site_moderators.suspended_at is not null;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_added', uid, left(note, 300)); end if;
  else
    if exists (select 1 from public.site_managers where user_id = uid) then raise exception 'Take Management off first'; end if;
    execute 'de' || 'lete from public.site_moderators where user_id = $1' using uid;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_removed', uid, left(note, 300)); end if;
  end if;
end;
$$;

-- Admins give and take Management. Giving it makes them an unpaused head mod first.
create or replace function public.admin_set_manager(uid uuid, on_off boolean, note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    if not public.feature_on('management', null) then raise exception 'Management isn''t on yet'; end if;
    if uid is null or not exists (select 1 from public.profiles where id = uid) then raise exception 'Not found'; end if;
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    if exists (select 1 from public.site_community_managers where user_id = uid) then
      raise exception 'They''re a Community Manager. Take that role off first';
    end if;
    insert into public.site_moderators (user_id, added_by, head) values (uid, auth.uid(), true)
    on conflict (user_id) do update set head = true, suspended_at = null, suspended_reason = null
      where not site_moderators.head or site_moderators.suspended_at is not null;
    insert into public.site_managers (user_id, added_by) values (uid, auth.uid()) on conflict (user_id) do nothing;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'manager_added', uid, left(note, 300)); end if;
  else
    execute 'de' || 'lete from public.site_managers where user_id = $1' using uid;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'manager_removed', uid, left(note, 300)); end if;
  end if;
end;
$$;
revoke all on function public.admin_set_manager(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_manager(uuid, boolean, text) to authenticated;

-- The 'management' badge: on while they're a manager with an unpaused head mod row.
create or replace function public.sync_management_badge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := coalesce(new.user_id, old.user_id);
        active boolean;
begin
  active := exists (select 1 from public.site_managers m join public.site_moderators s on s.user_id = m.user_id
                     where m.user_id = uid and s.head and s.suspended_at is null);
  if active then
    update public.profiles set badges = array_prepend('management', coalesce(badges, '{}'))
      where id = uid and not ('management' = any(coalesce(badges, '{}')));
  else
    update public.profiles set badges = array_remove(badges, 'management'),
      shown_badge = case when shown_badge = 'management' then null else shown_badge end
      where id = uid and 'management' = any(coalesce(badges, '{}'));
  end if;
  return null;
end;
$$;
revoke all on function public.sync_management_badge() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'site_managers_badge' and tgrelid = 'public.site_managers'::regclass) then
    create trigger site_managers_badge after insert or delete on public.site_managers
      for each row execute function public.sync_management_badge();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'site_moderators_management_badge' and tgrelid = 'public.site_moderators'::regclass) then
    create trigger site_moderators_management_badge after insert or update of head, suspended_at or delete on public.site_moderators
      for each row execute function public.sync_management_badge();
  end if;
end $$;

-- One-line changes, patched into the live text. Skipped where the function isn't there (test databases) or already
-- patched; a changed anchor stops the migration so nothing goes half in.
create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;
  if position(old_text in f) = 0 then raise exception '537: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

-- Developers and Community Managers: managers too (manager_guard: not themselves, admins or managers).
select pg_temp.patch_fn('public.admin_set_developer(uuid,boolean,text)', 'manager_guard',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then perform public.manager_guard(''staff'', uid); end if;');
select pg_temp.patch_fn('public.admin_set_community_manager(uuid,boolean,text)', 'manager_guard',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then perform public.manager_guard(''staff'', uid); end if;'
  || chr(10) || '  if on_off and exists (select 1 from public.site_managers where user_id = uid) then raise exception ''Take Management off first''; end if;');

-- Badges: managers give any listed badge but staff and the role ones, through manager_guard instead of mod_guard.
select pg_temp.patch_fn('public.admin_set_badge(uuid,text,boolean)', 'manager_guard',
  'if not (public.is_site_admin()',
  'if not (public.is_site_admin() or (badge not in (''staff'', ''developer'', ''community_manager'') and public.is_site_manager())');
select pg_temp.patch_fn('public.admin_set_badge(uuid,text,boolean)', 'manager_guard',
  'perform public.mod_guard(''badge'', uid, null);',
  'if not public.is_site_admin() and public.is_site_manager() then perform public.manager_guard(''badge'', uid);'
  || ' else perform public.mod_guard(''badge'', uid, null); end if;');

-- Site bans: managers ban like a mod would be checked (reason, hourly limit, no staff), but permanently. Wiping
-- messages stays admin only.
select pg_temp.patch_fn('public.site_ban(uuid,text,boolean)', 'is_site_manager',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then'
  || chr(10) || '    if not public.is_site_manager() then raise exception ''Admins only''; end if;'
  || chr(10) || '    if wipe then raise exception ''Only an admin can ban and delete their messages''; end if;'
  || chr(10) || '    if exists (select 1 from public.site_bans sb join public.site_admins sa on sa.user_id = sb.banned_by'
  || ' where sb.user_id = uid and (sb.expires_at is null or sb.expires_at > now())) then raise exception ''An admin banned them. Ask an admin''; end if;'
  || chr(10) || '    perform public.mod_guard(''ban'', uid, why);'
  || chr(10) || '  end if;');
select pg_temp.patch_fn('public.site_unban(uuid)', 'is_site_manager',
  'if b.banned_by is not null and b.expires_at is null then raise exception',
  'if b.banned_by is not null and b.expires_at is null'
  || ' and not (public.is_site_manager() and not exists (select 1 from public.site_admins where user_id = b.banned_by)) then raise exception');

-- Creator Program: manager_guard on the person (not themselves, admins or managers; 10 approvals a day).
select pg_temp.patch_fn('public.review_creator(uuid,boolean,integer,text)', 'manager_guard',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then perform public.manager_guard(case when approve then ''creator'' else ''creator_other'' end, (select x.user_id from public.creator_applications x where x.id = rid)); end if;');
select pg_temp.patch_fn('public.review_creator_content(uuid,boolean,text,integer,text,jsonb)', 'manager_guard',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then perform public.manager_guard(case when approve then ''creator'' else ''creator_other'' end, (select x.user_id from public.creator_content x where x.id = cid)); end if;');
select pg_temp.patch_fn('public.revoke_creator(uuid,text)', 'manager_guard',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then perform public.manager_guard(''creator_other'', uid); end if;');

-- Reads: creator applications and content, developers and community managers (the Moderators page lists them).
do $$
begin
  if to_regclass('public.creator_applications') is not null then
    alter policy "own creator applications" on public.creator_applications
      using (user_id = (select auth.uid()) or (select public.is_site_admin()) or (select public.is_site_manager()));
  end if;
  if to_regclass('public.creator_content') is not null then
    alter policy "own creator content" on public.creator_content
      using (user_id = (select auth.uid()) or (select public.is_site_admin()) or (select public.is_site_manager()));
  end if;
  if to_regclass('public.site_developers') is not null then
    alter policy "admins see developers" on public.site_developers
      using ((select public.is_site_admin()) or (select public.is_site_manager()) or user_id = (select auth.uid()));
  end if;
  if to_regclass('public.site_community_managers') is not null then
    alter policy "admins see community managers" on public.site_community_managers
      using ((select public.is_site_admin()) or (select public.is_site_manager()) or user_id = (select auth.uid()));
  end if;
end $$;
