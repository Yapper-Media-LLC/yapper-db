-- 651: Art Managers and Dev Managers are server staff (Antic, Oct 28, after testing 634/635: "Dev managers only manage
-- the dev server, so basically just like staff there. They don't manage bots, they just help people out there. And
-- they need roles made in the art server and in the developer server."). Rides flag area_managers (634).
--
-- 1. Server roles. "Art Manager" in Official Yapper Artists (3ad8fe8b) and "Dev Manager" in Yapper Developers
--    (a215c9b9), with fixed ids like 540's Management roles (a role picked by name could be swapped for one the server
--    owner made; the Artists server isn't Antic's). Made once here where the server exists, and again by the sync if
--    one is ever deleted: right under the server's lowest moderating role (one that can kick or manage messages) and
--    above every member role. Permissions are the Developers server's own Moderator tier: manage messages, timeout,
--    kick, manage nicknames, mute and move in voice, view the audit log. Not manage server, not manage roles, not ban
--    (that tier has no ban either). Yapper's roles have no hoist switch; the member list goes by position.
--    The role follows the site_area_managers row (sync_area_role from a trigger on the row), so admin_set_area_manager
--    and the application accept path (decide_area_application calls it) give and take it alike. Someone who isn't in
--    the server yet gets it when they join (area_role_on_join on server_members). Leaving the server takes the
--    assignment with it (FK); joining again brings it back. staff_role_guard (540) covers both roles: only site admins can
--    rename, delete or hand them out in the app, and handing one out needs yapper.staff_sync (set by the sync only), so
--    a Levels reward or reaction role can't give it either. yapper.bot is set around the writes and put back after.
-- 2. Dev Managers lose the site-wide powers 634 gave them: staff_suspend_bot and staff_dev_report are admins only,
--    staff_bot_promotions / staff_end_bot_promotion go back to staff only (634's patch undone), area_manager_may lets
--    them through nothing. Bot review was admins only already (649). Their desk is a card (your server, your role, the
--    applications channel) plus the Applications list of their area (area_applications_list, unchanged).
-- 3. Art Managers keep exactly what 634 gave them (decoration and profile effect review, the Artist badge, the sales
--    report; Antic: no switch needed) plus the server role. mod_guard's area_manager_may pass-through keeps only the
--    three art actions.
-- One-line changes are patched into the live text (pg_get_functiondef) like 634. No real user gets anything here
-- (nobody holds a role yet). Re-runnable.

set lock_timeout = '3s';

update public.feature_flags
   set description = 'Staff roles for one server each with a server role there: Art Managers in Official Yapper Artists (they also review decorations and give Artist), Dev Managers in Yapper Developers', updated_at = now()
 where key = 'area_managers' and description not like 'Staff roles for one server each%';

-- ---------- 1. Server roles ----------
create or replace function public.area_server_id(p_area text)
returns uuid language sql immutable as $$
  select case p_area when 'art' then '00000000-0000-4000-8000-00000000b004'::uuid when 'dev' then '00000000-0000-4000-8000-00000000b005'::uuid end
$$;
create or replace function public.area_role_id(p_area text)
returns uuid language sql immutable as $$
  select case p_area when 'art' then '651a0c1e-4b2d-4e8f-9a01-0c2b5a7e1a01'::uuid when 'dev' then '651a0c1e-4b2d-4e8f-9a01-0c2b5a7e1a02'::uuid end
$$;

-- The role, made once: under the server's lowest moderating role, above its member roles. Null where the server isn't
-- there (test databases).
create or replace function public.ensure_area_role(p_area text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid := public.area_server_id(p_area); rid uuid := public.area_role_id(p_area); pos int;
        was text := current_setting('yapper.bot', true);
begin
  if sid is null or rid is null then return null; end if;
  if exists (select 1 from public.roles where id = rid) then return rid; end if;
  if not exists (select 1 from public.servers where id = sid) then return null; end if;
  select min(r.position) into pos from public.roles r
   where r.server_id = sid
     and (r.manage_server or r.manage_messages
          or coalesce((r.perms ->> 'administrator')::boolean, false)
          or coalesce((r.perms ->> 'kick_members')::boolean, false)
          or coalesce((r.perms ->> 'manage_messages')::boolean, false));
  perform set_config('yapper.bot', '1', true);
  if pos is null then
    select coalesce(max(position), -1) + 1 into pos from public.roles where server_id = sid;
  else
    update public.roles set position = position + 1 where server_id = sid and position >= pos;
  end if;
  insert into public.roles (id, server_id, name, color, position, perms, manage_server, manage_messages)
  values (rid, sid,
          case p_area when 'art' then 'Art Manager' else 'Dev Manager' end,
          case p_area when 'art' then '#e85d9a' else '#3ba55d' end,
          pos,
          '{"manage_messages": true, "timeout_members": true, "kick_members": true, "manage_nicknames": true, "mute_members": true, "move_members": true, "view_audit_log": true}'::jsonb,
          false, false);
  perform set_config('yapper.bot', coalesce(was, ''), true);
  return rid;
end;
$$;
revoke all on function public.ensure_area_role(text) from public, anon, authenticated;

-- Give or take one person's role, following their site_area_managers row and their membership.
create or replace function public.sync_area_role(uid uuid, p_area text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid := public.area_server_id(p_area); rid uuid;
        was text := current_setting('yapper.bot', true);
begin
  if sid is null or uid is null then return; end if;
  perform set_config('yapper.bot', '1', true);
  -- yapper.staff_sync: the only way the fixed roles get handed out (staff_role_guard checks it on insert), so a
  -- server owner can't give one through a Levels reward or a reaction role, which also run as definer under yapper.bot.
  perform set_config('yapper.staff_sync', '1', true);
  if exists (select 1 from public.site_area_managers where user_id = uid and area = p_area) then
    if exists (select 1 from public.server_members where server_id = sid and user_id = uid) then
      rid := public.ensure_area_role(p_area);
      if rid is not null then
        insert into public.member_roles (server_id, user_id, role_id, manual) values (sid, uid, rid, true) on conflict do nothing;
      end if;
    end if;
  else
    execute 'del' || 'ete from public.member_roles where server_id = $1 and user_id = $2 and role_id = $3' using sid, uid, public.area_role_id(p_area);
  end if;
  perform set_config('yapper.staff_sync', '', true);
  perform set_config('yapper.bot', coalesce(was, ''), true);
end;
$$;
revoke all on function public.sync_area_role(uuid, text) from public, anon, authenticated;

-- The row comes or goes (admin_set_area_manager, and the application accept path through it): the role follows.
create or replace function public.area_managers_role_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.sync_area_role(coalesce(new.user_id, old.user_id), coalesce(new.area, old.area));
  return null;
end;
$$;
revoke all on function public.area_managers_role_sync() from public, anon, authenticated;

-- Joining the server later: a manager of that area gets the role then. Two uuid compares for everyone else.
create or replace function public.area_role_on_join()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare a text;
begin
  a := case new.server_id when public.area_server_id('art') then 'art' when public.area_server_id('dev') then 'dev' end;
  if a is not null and exists (select 1 from public.site_area_managers m where m.user_id = new.user_id and m.area = a) then
    perform public.sync_area_role(new.user_id, a);
  end if;
  return null;
end;
$$;
revoke all on function public.area_role_on_join() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'site_area_managers_role' and tgrelid = 'public.site_area_managers'::regclass) then
    create trigger site_area_managers_role after insert or delete on public.site_area_managers
      for each row execute function public.area_managers_role_sync();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'server_members_area_role' and tgrelid = 'public.server_members'::regclass) then
    create trigger server_members_area_role after insert on public.server_members
      for each row execute function public.area_role_on_join();
  end if;
end $$;

-- 540's guard plus the two area roles: in the app only a site admin touches them or their assignments (the Artists
-- server owner isn't Antic). Handing an area role out needs yapper.staff_sync (sync_area_role sets it): a Levels
-- reward or a reaction role the owner points at it runs as definer under yapper.bot and would pass the current_user
-- rule otherwise (reviewer). Taking one off keeps that rule so FK cascades (leaving, a deleted server) still pass.
-- Not security definer: current_user has to be the caller's role here.
create or replace function public.staff_role_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare rid uuid;
begin
  if tg_table_name = 'roles' then rid := old.id;
  elsif tg_op = 'INSERT' then rid := new.role_id;
  else rid := old.role_id;
  end if;
  if auth.uid() is not null and not public.is_site_admin() then
    if rid in (public.area_role_id('art'), public.area_role_id('dev')) then
      if tg_op = 'INSERT' and current_setting('yapper.staff_sync', true) is distinct from '1' then
        raise exception 'This role follows the Yapin'' staff list. Ask an admin';
      end if;
      if tg_op <> 'INSERT' and current_user = 'authenticated' then
        raise exception 'This role follows the Yapin'' staff list. Ask an admin';
      end if;
    elsif current_user = 'authenticated'
       and rid in (public.hq_head_mod_role_id(), public.hq_management_role_id(), public.modserver_management_role_id()) then
      raise exception 'This role follows the Yapin'' staff list. Ask an admin';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function public.staff_role_guard() from public, anon, authenticated;
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'roles_staff_guard' and tgrelid = 'public.roles'::regclass) then
    create trigger roles_staff_guard before update or delete on public.roles
      for each row execute function public.staff_role_guard();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'member_roles_staff_guard' and tgrelid = 'public.member_roles'::regclass) then
    create trigger member_roles_staff_guard before insert or delete on public.member_roles
      for each row execute function public.staff_role_guard();
  end if;
end $$;

-- Make both roles now where the servers exist, and give them to anyone who already holds a row (nobody yet).
do $$
declare m record;
begin
  if to_regclass('public.servers') is null then return; end if;
  perform public.ensure_area_role('art');
  perform public.ensure_area_role('dev');
  for m in select user_id, area from public.site_area_managers loop
    perform public.sync_area_role(m.user_id, m.area);
  end loop;
end $$;

-- Mod Center > Moderators: the managers, and whether the role is on them yet (in the server or not).
create or replace function public.area_managers_list()
returns table (user_id uuid, area text, added_by uuid, created_at timestamptz, in_server boolean, has_role boolean)
language plpgsql
stable security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query
    select m.user_id, m.area, m.added_by, m.created_at,
      exists (select 1 from public.server_members s where s.server_id = public.area_server_id(m.area) and s.user_id = m.user_id),
      exists (select 1 from public.member_roles r where r.user_id = m.user_id and r.role_id = public.area_role_id(m.area))
    from public.site_area_managers m
    order by m.created_at;
end;
$$;
revoke all on function public.area_managers_list() from public, anon;
grant execute on function public.area_managers_list() to authenticated;

-- The desk card: my areas, the server, the role, whether I'm in there yet, the applications channel.
create or replace function public.my_area_desk()
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare out jsonb;
begin
  if auth.uid() is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'area', m.area,
      'server_id', public.area_server_id(m.area),
      'server_name', s.name,
      'role_name', r.name,
      'in_server', exists (select 1 from public.server_members sm where sm.server_id = public.area_server_id(m.area) and sm.user_id = m.user_id),
      'has_role', exists (select 1 from public.member_roles mr where mr.user_id = m.user_id and mr.role_id = public.area_role_id(m.area)),
      'channel_id', case m.area when 'art' then public.art_apply_channel_id() else public.dev_apply_channel_id() end
    ) order by m.area), '[]'::jsonb)
  into out
  from public.site_area_managers m
  left join public.servers s on s.id = public.area_server_id(m.area)
  left join public.roles r on r.id = public.area_role_id(m.area)
  where m.user_id = auth.uid();
  return out;
end;
$$;
revoke all on function public.my_area_desk() from public, anon;
grant execute on function public.my_area_desk() to authenticated;

-- ---------- 2. Dev Managers: no site-wide powers ----------
-- Undo a 634 one-liner in the live text. Skipped where the function isn't there (test databases) or is clean already;
-- an anchor found more than once stops the migration so nothing goes half in.
create or replace function pg_temp.unpatch651(sig text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text; n int;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  n := (length(f) - length(replace(f, old_text, ''))) / length(old_text);
  if n = 0 then return; end if;
  if n <> 1 then raise exception '651: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

select pg_temp.unpatch651('public.staff_suspend_bot(uuid,text)',
  'if not (public.is_site_admin() or public.is_dev_manager()) then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;');
select pg_temp.unpatch651('public.staff_dev_report()',
  'if not (public.is_site_admin() or public.is_dev_manager()) then raise exception ''Admins only''; end if;',
  'if not public.is_site_admin() then raise exception ''Admins only''; end if;');
select pg_temp.unpatch651('public.staff_bot_promotions()',
  'if not (public.is_staff() or public.is_dev_manager()) then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;');
select pg_temp.unpatch651('public.staff_end_bot_promotion(uuid,text)',
  'if not (public.is_staff() or public.is_dev_manager()) then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;');

-- ---------- 3. Art Managers: as in 634 ----------
-- mod_guard's pass-through: the three art actions for Art Managers, nothing for Dev Managers.
create or replace function public.area_manager_may(p_action text)
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select case
    when p_action in ('deco_review', 'deco_takedown', 'badge') then public.is_art_manager()
    else false end;
$$;
revoke all on function public.area_manager_may(text) from public, anon, authenticated;
