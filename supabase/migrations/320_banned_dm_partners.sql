-- 320: the DM list hides chats with people banned from Yapper (Oct 20 bot wave: a hundred banned bots stayed in
-- everyone's DM list with unread badges). Only answers about people you share a DM with, so it can't be used to look
-- up whether anyone else is banned. Re-runnable.
create or replace function public.banned_dm_partners()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select distinct other.user_id
  from public.channel_members mine
  join public.channels c on c.id = mine.channel_id and c.kind = 'dm'
  join public.channel_members other on other.channel_id = c.id and other.user_id <> mine.user_id
  where mine.user_id = auth.uid()
    and public.is_site_banned(other.user_id)
$$;
revoke all on function public.banned_dm_partners() from public, anon;
grant execute on function public.banned_dm_partners() to authenticated;

insert into public.feature_flags (key, label, description, mode, servers)
values ('member_menu_site_ban', 'Ban from Yapper in the member menu', 'Staff get Ban from Yapper when they right-click someone in chat or the member list', 'test', '{}')
on conflict (key) do nothing;
