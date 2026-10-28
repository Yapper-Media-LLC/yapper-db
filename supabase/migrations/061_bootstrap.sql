-- Load like Discord: one request for everything the app needs at start, instead of ~15.
-- Both run as the database owner (security definer): row-level security on channel_members made
-- the planner check every row of the table (5s). Each part filters exactly like the policies it
-- replaces: my servers, my DMs, channels I can access, my own friend/ban rows.

create or replace function public.bootstrap()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with my_servers as (
    select sm.server_id from public.server_members sm where sm.user_id = auth.uid()
  ),
  my_cm as (
    select cm.channel_id, cm.hidden_at from public.channel_members cm where cm.user_id = auth.uid()
  ),
  dm_chans as (
    select c.* from public.channels c
    join my_cm on my_cm.channel_id = c.id
    where c.server_id is null
      and (my_cm.hidden_at is null or c.last_message_at > my_cm.hidden_at)
  ),
  dm_members as (
    select cm.channel_id, cm.user_id from public.channel_members cm where cm.channel_id in (select id from dm_chans)
  ),
  members as (
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at from public.server_members sm
    where sm.server_id in (select server_id from my_servers)
  ),
  small as (
    select server_id from members group by server_id having count(*) <= 300
  ),
  fr as (
    select requester, addressee, status from public.friendships where requester = auth.uid() or addressee = auth.uid()
  ),
  bl as (select blocked from public.blocks where blocker = auth.uid()),
  dr as (select from_id from public.dm_requests where to_id = auth.uid() order by created_at desc limit 100),
  pids as (
    select user_id as id from dm_members
    union select requester from fr
    union select addressee from fr
    union select blocked from bl
    union select from_id from dr
    union select user_id from members where server_id in (select server_id from small)
    union select auth.uid()
  )
  select jsonb_build_object(
    'now', now(),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from (
      select id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
             avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge
      from public.profiles where id in (select id from pids) limit 1500) p),
    'dm_channels', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from dm_chans c),
    'dm_members', (select coalesce(jsonb_agg(jsonb_build_array(channel_id, user_id)), '[]'::jsonb) from dm_members),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('channel_id', k.channel_id, 'started_by', k.started_by, 'started_at', k.started_at)), '[]'::jsonb) from public.calls k where k.ended_at is null and k.channel_id in (select id from dm_chans)),
    'servers', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from public.servers s where s.id in (select server_id from my_servers)),
    'channels', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.channels c where c.server_id in (select server_id from my_servers) and public.can_access_channel(c.id)),
    'channel_roles', (select coalesce(jsonb_agg(jsonb_build_array(channel_id, role_id)), '[]'::jsonb) from public.channel_roles where server_id in (select server_id from my_servers)),
    'post_roles', (select coalesce(jsonb_agg(jsonb_build_array(channel_id, role_id)), '[]'::jsonb) from public.channel_post_roles where server_id in (select server_id from my_servers)),
    'roles', (select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from public.roles r where r.server_id in (select server_id from my_servers)),
    -- Automatic roles (everyone / joined-before) are worked out on the device, so their stored rows are skipped.
    'member_roles', (select coalesce(jsonb_agg(jsonb_build_array(mr.server_id, mr.user_id, mr.role_id)), '[]'::jsonb)
      from public.member_roles mr
      where mr.server_id in (select server_id from my_servers)
        and not exists (select 1 from public.roles r where r.id = mr.role_id and r.auto <> 'none')),
    -- [user id, joined (unix seconds), nickname?] per server: compact, big servers have thousands.
    'members', (select coalesce(jsonb_object_agg(server_id, arr), '{}'::jsonb) from (
      select server_id, jsonb_agg(case when nickname is null then jsonb_build_array(user_id, extract(epoch from joined_at)::bigint)
                                       else jsonb_build_array(user_id, extract(epoch from joined_at)::bigint, nickname) end) as arr
      from members group by server_id) x),
    'friends', (select coalesce(jsonb_agg(jsonb_build_array(requester, addressee, status)), '[]'::jsonb) from fr),
    'blocks', (select coalesce(jsonb_agg(blocked), '[]'::jsonb) from bl),
    'dm_requests', (select coalesce(jsonb_agg(from_id), '[]'::jsonb) from dr),
    'unread', (select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) from public.unread_counts_v2() u),
    'server_mutes', (select coalesce(jsonb_agg(server_id), '[]'::jsonb) from public.server_mutes where user_id = auth.uid()),
    'flags', (select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) from (select key, label, description, mode, servers, users from public.feature_flags) f),
    'emojis', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from public.emojis e where e.server_id in (select server_id from my_servers)),
    'categories', (select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb) from public.channel_categories k where k.server_id in (select server_id from my_servers)),
    'is_admin', exists (select 1 from public.site_admins where user_id = auth.uid()),
    'mod', (select to_jsonb(m) from (select suspended_at from public.site_moderators where user_id = auth.uid()) m),
    'ban', (select to_jsonb(b) from (select reason, created_at, expires_at from public.site_bans where user_id = auth.uid()) b)
  );
$$;
grant execute on function public.bootstrap() to authenticated;

-- One channel's messages with the people who wrote them and the reactions: one request
-- instead of three, and names are there before the messages paint (no more "Someone").
create or replace function public.channel_messages(cid uuid, before timestamptz default null, lim int default 50)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with msgs as (
    select m.* from public.messages m
    where m.channel_id = cid and public.can_access_channel(cid) and (before is null or m.created_at < before)
    order by m.created_at desc
    limit least(greatest(coalesce(lim, 50), 1), 100)
  )
  select jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from msgs m),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from (
      select id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
             avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge
      from public.profiles where id in (select author_id from msgs)) p),
    'reactions', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'message_id', r.message_id, 'user_id', r.user_id, 'emoji', r.emoji)), '[]'::jsonb)
      from public.reactions r where r.message_id in (select id from msgs))
  );
$$;
grant execute on function public.channel_messages(uuid, timestamptz, int) to authenticated;

create index if not exists friendships_requester_idx on public.friendships (requester);
