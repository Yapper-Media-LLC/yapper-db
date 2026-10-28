-- 540: server roles for Yapin' Management (Antic, Oct 26: "make appropriate roles aswell both in mod serv and hq").
-- One "Yapin' Management" role in Yapper Headquarters and one in the Moderator Server, each right above Head Moderator
-- (HQ: above Developer too, under Admin), red like the badge, with Head Moderator's permissions. Fixed ids like 365's
-- hq_head_mod_role_id(): picking a role by name would let anyone who can make roles point the trigger at their own.
-- sync_management_badge (537) now also gives and takes both roles with the badge, for people in those servers.
-- Roles are made only the first time (re-runnable); nobody is given one here (no managers exist yet).

set lock_timeout = '3s';

create or replace function public.hq_management_role_id()
returns uuid language sql immutable as $$ select 'c9c2a8dd-196a-4bf7-b23b-309f94ba1cc6'::uuid $$;
create or replace function public.modserver_management_role_id()
returns uuid language sql immutable as $$ select 'f7d69cb5-8e0c-4fd8-aa62-2f04c76dcc4a'::uuid $$;

do $$
declare
  hq constant uuid := '00000000-0000-4000-8000-00000000b002';
  ms constant uuid := '00000000-0000-4000-8000-00000000b003';
  pos int; perms_ jsonb;
begin
  perform set_config('yapper.bot', '1', true);
  -- HQ: above Developer (or Head Moderator), under Admin.
  if exists (select 1 from public.servers where id = hq) and not exists (select 1 from public.roles where id = public.hq_management_role_id()) then
    select r.position into pos from public.roles r where r.server_id = hq and r.name in ('Developer', 'Head Moderator') order by r.position desc limit 1;
    select r.perms into perms_ from public.roles r where r.id = public.hq_head_mod_role_id();
    if pos is not null then
      update public.roles set position = position + 1 where server_id = hq and position > pos;
      insert into public.roles (id, server_id, name, color, position, perms, manage_server, manage_messages)
      values (public.hq_management_role_id(), hq, 'Yapin'' Management', '#d83c3e', pos + 1, coalesce(perms_, '{}'), false, false);
    end if;
  end if;
  -- Moderator Server: above Head Moderator.
  pos := null; perms_ := null;
  if exists (select 1 from public.servers where id = ms) and not exists (select 1 from public.roles where id = public.modserver_management_role_id()) then
    select r.position, r.perms into pos, perms_ from public.roles r where r.server_id = ms and r.name = 'Head Moderator' order by r.position desc limit 1;
    if pos is not null then
      update public.roles set position = position + 1 where server_id = ms and position > pos;
      insert into public.roles (id, server_id, name, color, position, perms, manage_server, manage_messages)
      values (public.modserver_management_role_id(), ms, 'Yapin'' Management', '#d83c3e', pos + 1, coalesce(perms_, '{}'), false, false);
    end if;
  end if;
  perform set_config('yapper.bot', '', true);
end $$;

-- The staff roles follow the site roles only. A manager's top HQ role sits above Head Moderator, so with Head
-- Moderator's manage_roles they could otherwise rename, take, delete or hand out it and the Management roles (and
-- sync_mod_badge would quietly stop once the row was gone). People acting in the app can't touch these three rows or
-- their assignments unless they're a site admin; the sync triggers run as the definer and pass.
create or replace function public.staff_role_guard()
returns trigger
language plpgsql
set search_path = public
as $$
-- Not security definer: current_user has to be the caller's role here (definer triggers and FK cascades pass).
declare rid uuid;
begin
  if tg_table_name = 'roles' then rid := old.id;
  elsif tg_op = 'INSERT' then rid := new.role_id;
  else rid := old.role_id;
  end if;
  if current_user = 'authenticated' and auth.uid() is not null
     and rid in (public.hq_head_mod_role_id(), public.hq_management_role_id(), public.modserver_management_role_id())
     and not public.is_site_admin() then
    raise exception 'This role follows the Yapin'' staff list. Ask an admin';
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

-- 537's trigger plus the two roles. yapper.bot goes back to what it was (this can run inside another bot write).
create or replace function public.sync_management_badge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := coalesce(new.user_id, old.user_id);
        active boolean;
        was text := current_setting('yapper.bot', true);
        r record;
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
  perform set_config('yapper.bot', '1', true);
  for r in select ro.id, ro.server_id from public.roles ro
            where ro.id in (public.hq_management_role_id(), public.modserver_management_role_id()) loop
    if active then
      if exists (select 1 from public.server_members where server_id = r.server_id and user_id = uid) then
        insert into public.member_roles (server_id, user_id, role_id, manual) values (r.server_id, uid, r.id, true) on conflict do nothing;
      end if;
    else
      execute 'del' || 'ete from public.member_roles where server_id = $1 and user_id = $2 and role_id = $3' using r.server_id, uid, r.id;
    end if;
  end loop;
  perform set_config('yapper.bot', coalesce(was, ''), true);
  return null;
end;
$$;
revoke all on function public.sync_management_badge() from public, anon, authenticated;
