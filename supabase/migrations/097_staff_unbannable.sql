-- Yapper staff (admins and active moderators) can't be banned or kicked from servers (Oct 15).
-- The ban trigger is applied live. kick_member and the clean-up need the SQL editor.
create or replace function public.no_banning_staff()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if public.is_staff_user(new.user_id) then
    raise exception 'You can''t ban Yapper staff from a server. Report them to an admin instead.' using errcode = 'check_violation';
  end if;
  return new;
end; $function$;
drop trigger if exists server_bans_no_staff on public.server_bans;
create trigger server_bans_no_staff before insert on public.server_bans
  for each row execute function public.no_banning_staff();

create or replace function public.kick_member(sid uuid, target uuid)
 returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t kick people here'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then
    raise exception 'You can''t kick the owner';
  end if;
  if public.is_staff_user(target) then raise exception 'You can''t kick Yapper staff from a server. Report them to an admin instead.'; end if;
  delete from public.server_members where server_id = sid and user_id = target;
  delete from public.invites where server_id = sid and created_by = target;
end;
$function$;

-- Lift the server bans that already hit staff.
delete from public.server_bans b where public.is_staff_user(b.user_id);
