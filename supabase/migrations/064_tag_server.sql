-- Clicking someone's server tag shows that server and lets you join it (if it's public).
create or replace function public.tag_server(sid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'icon_path', s.icon_path, 'tag', s.tag,
    'description', coalesce(s.description, ''),
    'discoverable', coalesce(s.discoverable, false),
    'member_count', (select count(*) from public.server_members m where m.server_id = s.id),
    'joined', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid())
  )
  from public.servers s where s.id = sid and auth.uid() is not null;
$$;
revoke all on function public.tag_server(uuid) from public, anon;
grant execute on function public.tag_server(uuid) to authenticated;
