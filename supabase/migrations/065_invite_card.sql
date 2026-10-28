-- The card shown under an invite link in chat (like Discord): server, counts, join state.
create or replace function public.invite_card(invite_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'server_id', s.id, 'name', s.name, 'icon_path', s.icon_path,
    'banner_path', s.banner_path, 'banner_x', s.banner_x, 'banner_y', s.banner_y, 'banner_zoom', s.banner_zoom,
    'created_at', s.created_at,
    'member_count', (select count(*) from public.server_members m where m.server_id = s.id),
    'online_count', (select count(*) from public.server_members m join public.presence p on p.user_id = m.user_id
                     where m.server_id = s.id and p.last_seen > now() - interval '100 seconds'),
    'already_member', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid())
  )
  from public.invites i join public.servers s on s.id = i.server_id
  where i.code = invite_code;
$$;
revoke all on function public.invite_card(text) from public;
grant execute on function public.invite_card(text) to anon, authenticated;
