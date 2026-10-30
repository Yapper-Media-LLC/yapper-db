-- 669: Role changes in HQ and the Moderator Server failed with "permission denied for function is_staff_user"
-- (app: "Yapin' was updated. Refresh"; bug report from Tripex, Oct 29). 657's staff_role_guard runs as the person
-- changing roles (not security definer, it reads current_user) and calls is_staff_user, which only postgres and
-- service_role may execute: the staff list is private (site_moderators is readable by admins and head mods only).
-- Postgres checks EXECUTE when it prepares an IF condition, before any "and" can skip the call, so every give
-- and every take in those two servers failed, not only taking roles from staff. 22 failures 09:43-11:14 UTC.
-- Now the guard asks role_guard_is_staff, a security definer wrapper that only answers inside the two staff servers,
-- about a member of that server, for someone who may manage roles there (or a site admin): the people the guard is
-- there to stop. Anyone else gets false, which changes nothing for them (they can't take other people's roles or
-- delete roles there anyway). Owning some other server gets you nothing: what's left is HQ/Moderator Server managers
-- asking about members there, which the staff-list roles in those servers already show. staff_role_guard is 657's text with those two calls swapped. Re-runnable.

set lock_timeout = '3s';

create or replace function public.role_guard_is_staff(sid uuid, uid uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select case when sid in (select x.server_id from public.roles x
                           where x.id in (public.hq_management_role_id(), public.modserver_management_role_id()))
               and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = uid)
               and (public.is_site_admin() or public.server_perm(sid, 'manage_roles'))
          then public.is_staff_user(uid) else false end;
$function$;

revoke all on function public.role_guard_is_staff(uuid, uuid) from public, anon;
grant execute on function public.role_guard_is_staff(uuid, uuid) to authenticated, service_role;

create or replace function public.staff_role_guard()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare rid uuid; staff_server boolean; admin_role boolean;
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
    -- 657: a role never moves to another server (an Administrator role made elsewhere could be moved into a staff
    -- server; the staff check below reads the old row).
    if tg_table_name = 'roles' and tg_op = 'UPDATE' and current_user = 'authenticated' then
      if new.server_id is distinct from old.server_id then
        raise exception 'A role can''t move to another server';
      end if;
    end if;
    -- 657: the staff servers (HQ, Moderator Server). Not limited to current_user = 'authenticated' where noted:
    -- reaction roles add and take roles from a security definer trigger, and the person reacting is still auth.uid().
    select r.server_id in (select x.server_id from public.roles x
                           where x.id in (public.hq_management_role_id(), public.modserver_management_role_id()))
      into staff_server
      from public.roles r where r.id = rid;
    if coalesce(staff_server, false) then
      if tg_table_name = 'member_roles' then
        select coalesce((r.perms ->> 'administrator')::boolean, false) into admin_role from public.roles r where r.id = rid;
        if tg_op = 'INSERT' and coalesce(admin_role, false) then
          raise exception 'Only a Yapin'' admin can give a role with Administrator here';
        end if;
        -- Taking a role from someone else: not from Yapin' staff, and no Administrator role from anyone (two
        -- managers holding Administrator could strip each other). You can still give up your own roles (that's all an
        -- un-react can take). Only direct deletes: the staff syncs (540, 651), kicks and leaving run as the owner.
        if tg_op = 'DELETE' and old.user_id is distinct from auth.uid()
           and current_user = 'authenticated'
           and (coalesce(admin_role, false) or public.role_guard_is_staff(old.server_id, old.user_id)) then
          raise exception 'Only a Yapin'' admin can take roles from Yapin'' staff here';
        end if;
      end if;
      -- Nested: member_roles rows have no perms, and plpgsql resolves new.perms even behind a false "and".
      if tg_table_name = 'roles' and current_user = 'authenticated' then
        if tg_op = 'DELETE' then
          if coalesce((old.perms ->> 'administrator')::boolean, false) then
            raise exception 'Only a Yapin'' admin can delete a role with Administrator here';
          end if;
          -- Deleting the role would take it from staff through the cascade, which runs as the owner.
          if exists (select 1 from public.member_roles mr where mr.role_id = old.id and public.role_guard_is_staff(old.server_id, mr.user_id)) then
            raise exception 'Only a Yapin'' admin can delete a role Yapin'' staff hold here';
          end if;
        elsif (coalesce((new.perms ->> 'administrator')::boolean, false) or coalesce((old.perms ->> 'administrator')::boolean, false))
              and new.perms is distinct from old.perms then
          -- Turning it on, off, or changing what such a role can do. Moving it in the list stays open.
          raise exception 'Only a Yapin'' admin can change a role with Administrator here';
        end if;
      end if;
    end if;
  end if;
  return coalesce(new, old);
end;
$function$;
