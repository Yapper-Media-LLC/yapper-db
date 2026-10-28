-- Server banners can be cropped (framing stored like profile banners; the file itself is untouched).
alter table public.servers add column if not exists banner_x numeric not null default 50, add column if not exists banner_y numeric not null default 50, add column if not exists banner_zoom numeric not null default 1;
drop function if exists public.set_server_banner(uuid, text);
create or replace function public.set_server_banner(sid uuid, p text, bx numeric default 50, by numeric default 50, bz numeric default 1)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if p is not null then
    if p !~ ('^' || auth.uid()::text || '/') then raise exception 'Bad banner'; end if;
    if not public.media_ok('banners', p) then raise exception 'That image hasn''t been checked yet'; end if;
  end if;
  update public.servers set banner_path = p, banner_x = least(100, greatest(0, coalesce(bx, 50))), banner_y = least(100, greatest(0, coalesce(by, 50))), banner_zoom = least(3, greatest(1, coalesce(bz, 1))) where id = sid;
end;
$$;
revoke all on function public.set_server_banner(uuid, text, numeric, numeric, numeric) from public, anon;
grant execute on function public.set_server_banner(uuid, text, numeric, numeric, numeric) to authenticated;

create or replace function public.discover_servers_v2(q text default '', lim int default 48)
returns table (id uuid, name text, icon_path text, banner_path text, banner_x numeric, banner_y numeric, banner_zoom numeric, description text, tags text[], members int, joined boolean)
language sql stable security definer set search_path = public as $$
  select * from (
    select s.id, s.name, s.icon_path, s.banner_path, s.banner_x, s.banner_y, s.banner_zoom, s.description, s.tags,
           (select count(*)::int from public.server_members m where m.server_id = s.id) as members,
           exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid()) as joined
    from public.servers s
    where s.discoverable
      and not public.is_site_banned(s.owner_id)
      and not public.bad_name(s.name)
      and (coalesce(q, '') = '' or s.name ilike '%' || q || '%' or s.description ilike '%' || q || '%' or lower(q) = any(s.tags))
  ) x
  where x.members >= 5
  order by x.members desc
  limit least(coalesce(lim, 48), 100);
$$;
revoke all on function public.discover_servers_v2(text, int) from public, anon;
grant execute on function public.discover_servers_v2(text, int) to authenticated;
