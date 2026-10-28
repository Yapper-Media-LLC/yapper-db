-- Role hierarchy (applied live Oct 14). Bug reports f89b9b9a / 4c4c0e4b: anyone with Manage Roles could give
-- themselves a role above their own, or edit a higher role to add dangerous permissions. Now, unless you own
-- the server: you can only give, create or edit roles below your own highest role, and only the owner can
-- hand out Administrator. Service-role writes (templates, triggers) are not affected.
create or replace function public.my_top_role_position(sid uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(max(r.position), -1) from public.member_roles mr join public.roles r on r.id = mr.role_id
  where mr.server_id = sid and mr.user_id = auth.uid();
$$;

create or replace function public.role_rank_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare pos int;
begin
  -- Service role, templates and triggers: not a person acting.
  if auth.uid() is null or current_user <> 'authenticated' then return new; end if;
  if exists (select 1 from public.servers where id = new.server_id and owner_id = auth.uid()) then return new; end if;
  select position into pos from public.roles where id = new.role_id;
  if pos >= public.my_top_role_position(new.server_id) then
    raise exception 'You can only give roles below your own highest role';
  end if;
  return new;
end; $$;
drop trigger if exists member_roles_rank_guard on public.member_roles;
create trigger member_roles_rank_guard before insert on public.member_roles
  for each row execute function public.role_rank_guard();

create or replace function public.role_edit_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare top int;
begin
  if auth.uid() is null or current_user <> 'authenticated' then return new; end if;
  if exists (select 1 from public.servers where id = new.server_id and owner_id = auth.uid()) then return new; end if;
  top := public.my_top_role_position(new.server_id);
  if tg_op = 'UPDATE' and old.position >= top then raise exception 'You can only edit roles below your own highest role'; end if;
  if new.position >= top then raise exception 'Put the role below your own highest role'; end if;
  if coalesce((new.perms->>'administrator')::boolean, false) and (tg_op = 'INSERT' or not coalesce((old.perms->>'administrator')::boolean, false)) then
    raise exception 'Only the server owner can hand out Administrator';
  end if;
  return new;
end; $$;
drop trigger if exists roles_edit_guard on public.roles;
create trigger roles_edit_guard before insert or update on public.roles
  for each row execute function public.role_edit_guard();
