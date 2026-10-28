-- ============================================================
-- Yapper · Kicks stick a bit better
-- Kicking someone also deletes the invite links they made, so they
-- can't just walk back in with their own link.
-- ============================================================

create or replace function public.kick_member(sid uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t kick people here'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then
    raise exception 'You can''t kick the owner';
  end if;
  delete from public.server_members where server_id = sid and user_id = target;
  delete from public.invites where server_id = sid and created_by = target;
end;
$$;
