-- 657: In the staff servers (HQ and the Moderator Server) only a site admin may hand out a role that carries
-- Administrator, change or delete such a role, or take roles from Yapin' staff (Antic, Oct 29: the two managers holding
-- "." could strip each other's roles). Kicking and banning staff was already refused everywhere (kick_member and the
-- server_bans triggers check is_staff_user). Antic's "." role in the Moderator Server has Administrator
-- (for managers); a manager ranked above it gave it to a head mod (Oct 27 23:50 UTC), who could then read the private
-- #management-chat until it was taken back on Oct 28 11:24 UTC. Administrator skips every private channel and
-- override, so in these two servers it's the admins' call alone. Everything else in staff_role_guard is the live text as of Oct 29 2026. Re-runnable.

set lock_timeout = '3s';

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
           and (coalesce(admin_role, false) or public.is_staff_user(old.user_id)) then
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
          if exists (select 1 from public.member_roles mr where mr.role_id = old.id and public.is_staff_user(mr.user_id)) then
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
