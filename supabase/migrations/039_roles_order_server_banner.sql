-- Reorder roles (Server Settings → Roles arrows) and server banners.
create or replace function public.reorder_roles(sid uuid, ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare n int; i int;
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t rearrange roles here'; end if;
  n := coalesce(array_length(ids, 1), 0);
  -- ids come top-first; the top role gets the highest position.
  for i in 1 .. n loop
    update public.roles set position = n - i where id = ids[i] and server_id = sid;
  end loop;
end;
$$;
revoke all on function public.reorder_roles(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_roles(uuid, uuid[]) to authenticated;

alter table public.servers add column if not exists banner_path text;
create or replace function public.set_server_banner(sid uuid, p text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if p is not null then
    if p !~ ('^' || auth.uid()::text || '/') then raise exception 'Bad banner'; end if;
    if not public.media_ok('banners', p) then raise exception 'That image hasn''t been checked yet'; end if;
  end if;
  update public.servers set banner_path = p where id = sid;
end;
$$;
revoke all on function public.set_server_banner(uuid, text) from public, anon;
grant execute on function public.set_server_banner(uuid, text) to authenticated;
