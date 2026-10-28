-- Big servers no longer ship their whole member list. HQ has 28k members (13k of them joined in one day
-- from a bot farm); every app open pulled all of them through bootstrap() (2.4 s, 3 MB) and, when that
-- timed out (authenticated has a 5 s statement timeout), the fallback paged through them again. The
-- database sat at 98% CPU. Now servers over 3,000 members send: you, everyone with a real role, everyone
-- seen in the last 10 minutes, and the 300 newest joiners. The count comes separately.

create or replace function public.server_members_slice(sids uuid[])
returns table(server_id uuid, user_id uuid, nickname text, joined_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  with sz as (
    select s.server_id, count(*) n from public.server_members s where s.server_id = any(sids) group by s.server_id
  ),
  big as (select sz.server_id from sz where sz.n > 3000),
  small as (select sz.server_id from sz where sz.n <= 3000)
  select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
  from public.server_members sm where sm.server_id in (select server_id from small)
  union
  select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
  from public.server_members sm where sm.server_id in (select server_id from big) and sm.user_id = auth.uid()
  union
  select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
  from public.roles r
  join public.member_roles mr on mr.role_id = r.id
  join public.server_members sm on sm.server_id = mr.server_id and sm.user_id = mr.user_id
  where r.server_id in (select server_id from big) and (r.auto = 'none' or mr.manual)
  union
  select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
  from public.presence p
  join public.server_members sm on sm.user_id = p.user_id
  where p.last_seen > now() - interval '10 minutes' and sm.server_id in (select server_id from big)
  union
  select r.server_id, r.user_id, r.nickname, r.joined_at
  from big
  cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = big.server_id order by x.joined_at desc limit 300) r;
$$;
grant execute on function public.server_members_slice(uuid[]) to authenticated;

create or replace function public.server_member_counts(sids uuid[])
returns table(server_id uuid, n bigint)
language sql stable security definer set search_path to 'public' as $$
  select s.server_id, count(*) from public.server_members s where s.server_id = any(sids) group by s.server_id;
$$;
grant execute on function public.server_member_counts(uuid[]) to authenticated;

create or replace function public.bootstrap()
returns jsonb
language sql stable security definer set search_path to 'public' as $$
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
    select * from public.server_members_slice((select coalesce(array_agg(server_id), '{}'::uuid[]) from my_servers))
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
    'member_roles', (select coalesce(jsonb_agg(jsonb_build_array(mr.server_id, mr.user_id, mr.role_id)), '[]'::jsonb)
      from public.member_roles mr
      where mr.server_id in (select server_id from my_servers)
        and not exists (select 1 from public.roles r where r.id = mr.role_id and r.auto <> 'none')),
    'members', (select coalesce(jsonb_object_agg(server_id, arr), '{}'::jsonb) from (
      select server_id, jsonb_agg(case when nickname is null then jsonb_build_array(user_id, extract(epoch from joined_at)::bigint)
                                       else jsonb_build_array(user_id, extract(epoch from joined_at)::bigint, nickname) end) as arr
      from members group by server_id) x),
    'member_counts', (select coalesce(jsonb_object_agg(server_id, n), '{}'::jsonb) from public.server_member_counts((select coalesce(array_agg(server_id), '{}'::uuid[]) from my_servers))),
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
