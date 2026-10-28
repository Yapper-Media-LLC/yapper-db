-- 186 (applied live as 182): Administrators could move any role above their own highest role (17 Oct report from PSA).
-- reorder_roles let Administrator reorder freely, and as a security definer function the role guards
-- (which skip non-'authenticated' callers) didn't run. An admin could drag a spare role above Owner,
-- then hand out Owner (or any role) to anyone. Now only the server owner reorders freely; everyone
-- else, Administrator included, only shuffles the roles below their own highest role, among the
-- places those roles already hold (like Discord). Re-runnable.

create or replace function public.reorder_roles(sid uuid, ids uuid[])
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare n int; i int; tp int; below uuid[]; slots int[];
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  n := coalesce(array_length(ids, 1), 0);
  if exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    for i in 1 .. n loop
      update public.roles set position = n - i where id = ids[i] and server_id = sid;
    end loop;
    return;
  end if;
  if not (public.server_perm(sid, 'manage_roles') or public.server_perm(sid, 'administrator')) then
    raise exception 'You need Manage Roles to rearrange roles';
  end if;
  -- Only the roles below your highest role, among the places they already hold.
  select coalesce(max(r.position), -1) into tp from public.roles r join public.member_roles mr on mr.role_id = r.id
    where r.server_id = sid and mr.server_id = sid and mr.user_id = auth.uid();
  select array_agg(x.id order by x.ord) into below from (
    select r.id, min(u.ord) ord from unnest(ids) with ordinality u(id, ord) join public.roles r on r.id = u.id
    where r.server_id = sid and r.position < tp group by r.id) x;
  select array_agg(r.position order by r.position desc) into slots from public.roles r where r.id = any(below);
  if below is null then raise exception 'You can only move roles below your highest role'; end if;
  for i in 1 .. array_length(below, 1) loop
    update public.roles set position = slots[i] where id = below[i];
  end loop;
end;
$function$;

revoke all on function public.reorder_roles(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_roles(uuid, uuid[]) to authenticated;
