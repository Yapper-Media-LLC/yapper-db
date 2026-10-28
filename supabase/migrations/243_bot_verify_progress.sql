-- What a bot still needs before Yapper verifies it, for the checklist next to "Publish for review"
-- (Settings > Developer > bot > Community). Owner only. Same bar staff use when reviewing:
-- in 3+ servers the owner doesn't own that have 3+ members, online in the last 7 days, a picture,
-- at least one command, a 20+ character description.
create or replace function public.bot_verify_progress(bid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b public.bots;
begin
  select * into b from public.bots where id = bid and owner_id = auth.uid();
  if b.id is null then raise exception 'Bot not found'; end if;
  return jsonb_build_object(
    'servers', (select count(*) from public.bot_servers bs where bs.bot_id = b.id),
    'real_servers', (select count(*) from public.bot_servers bs join public.servers s on s.id = bs.server_id
                      where bs.bot_id = b.id and s.owner_id <> b.owner_id and s.member_count >= 3),
    'need_servers', 3,
    'has_avatar', exists (select 1 from public.profiles p where p.id = b.id and p.avatar_path is not null),
    'commands', (select count(*) from public.bot_commands c where c.bot_id = b.id),
    'online', coalesce(greatest(b.last_poll_at, b.last_event_at) > now() - interval '7 days', false),
    'description_ok', char_length(btrim(coalesce(b.description, ''))) >= 20
  );
end $$;
revoke all on function public.bot_verify_progress(uuid) from public, anon;
grant execute on function public.bot_verify_progress(uuid) to authenticated;
