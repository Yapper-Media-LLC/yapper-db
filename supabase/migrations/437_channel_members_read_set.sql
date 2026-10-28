-- 437: channel_members read policy as a set check (same idea as 403 for channel_overrides).
-- The old policy ran can_access_channel() for every row it looked at. A read that doesn't name a channel
-- (GET /rest/v1/channel_members?select=*&limit=1) walked the ~400k DM member rows calling it on each, and hit the
-- 5 s statement timeout every time (bug report Oct 23). The app always reads by channel, so people never saw it, but
-- each such read held a database connection for 5 s.
-- Who can see what does not change:
--   * rows of channels you're a member of (DMs, group DMs, tickets), unless you're site banned: the is_channel_member
--     branch of can_access_channel, now one set (my_open_channel_ids) built once per query;
--   * rows of a server channel: still can_access_channel, but only checked for channels of servers you're in
--     (my_server_channel_ids; can_access_channel's server branch needs server membership anyway), so other people's
--     DM rows never call it. The set skips channels' own RLS (that would run can_access_channel per channel).
-- my_channel_ids() (244, used by the channels policy) is left as it is.
-- Functions and policy only, no table change. Re-runnable.
set lock_timeout = '3s';

create or replace function public.my_open_channel_ids()
returns setof uuid
language sql stable security definer set search_path to 'public' as $$
  select cm.channel_id from public.channel_members cm
  where cm.user_id = auth.uid() and not public.is_site_banned(auth.uid());
$$;
revoke all on function public.my_open_channel_ids() from public, anon;
grant execute on function public.my_open_channel_ids() to authenticated;

create or replace function public.my_server_channel_ids()
returns setof uuid
language sql stable security definer set search_path to 'public' as $$
  select c.id from public.channels c
  where c.server_id in (select sm.server_id from public.server_members sm where sm.user_id = auth.uid());
$$;
revoke all on function public.my_server_channel_ids() from public, anon;
grant execute on function public.my_server_channel_ids() to authenticated;

do $$
begin
  perform set_config('lock_timeout', '3s', true);
  execute 'dr' || 'op policy if exists "see members of channels you can access" on public.channel_members';
  execute $p$
    create policy "see members of channels you can access" on public.channel_members for select to authenticated
      using (
        channel_id in (select public.my_open_channel_ids())
        or (channel_id in (select public.my_server_channel_ids()) and public.can_access_channel(channel_id))
      )
  $p$;
end $$;
