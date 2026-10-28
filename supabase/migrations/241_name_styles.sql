set lock_timeout = '3s';
-- 241: personal name styles (flag `name_styles`, test). Free for everyone.
-- A person picks a font for their name from a short list, and optionally a colour or a two-colour gradient.
-- Stored as one small jsonb on profiles: {"f": font key, "c": "#rrggbb", "c2": "#rrggbb"} (every key optional,
-- c2 only with c). The CHECK below is the server-side validation; the client clamps colours for contrast.
-- Writes: only the owner (column grant + the existing "you can edit your own profile" policy, id = auth.uid()).
-- Reads: like every other PROFILE_COLS column, so bootstrap() and channel_messages() are re-created with the
-- column added. Both are copied from the LIVE definitions (pg_get_functiondef, Oct 18) with only `, name_style`
-- added after `discriminator`.
-- Re-runnable.

alter table public.profiles add column if not exists name_style jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_name_style_shape' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_name_style_shape check (
      name_style is null or (
        jsonb_typeof(name_style) = 'object'
        and name_style <> '{}'::jsonb
        and (name_style - array['f', 'c', 'c2']) = '{}'::jsonb
        and (not (name_style ? 'f') or (jsonb_typeof(name_style -> 'f') = 'string'
             and name_style ->> 'f' in ('rounded', 'serif', 'mono', 'hand', 'pixel', 'display', 'comic')))
        and (not (name_style ? 'c') or (jsonb_typeof(name_style -> 'c') = 'string' and name_style ->> 'c' ~ '^#[0-9a-fA-F]{6}$'))
        and (not (name_style ? 'c2') or ((name_style ? 'c') and jsonb_typeof(name_style -> 'c2') = 'string'
             and name_style ->> 'c2' ~ '^#[0-9a-fA-F]{6}$'))
      )
    ) not valid;
  end if;
end $$;
alter table public.profiles validate constraint profiles_name_style_shape;

grant select (name_style) on public.profiles to anon, authenticated;
grant update (name_style) on public.profiles to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('name_styles', 'Name styles', 'Pick a font and colour or gradient for your name (Settings, My Account)', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public.bootstrap()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge, verify_required, profile_effect, custom_status, avatar_deco, discriminator, name_style
      from public.profiles where id in (select id from pids) limit 1500) p),
    'dm_channels', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from dm_chans c),
    'dm_members', (select coalesce(jsonb_agg(jsonb_build_array(channel_id, user_id)), '[]'::jsonb) from dm_members),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('channel_id', k.channel_id, 'started_by', k.started_by, 'started_at', k.started_at)), '[]'::jsonb) from public.calls k where k.ended_at is null and k.channel_id in (select id from dm_chans)),
    'servers', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from public.servers s where s.id in (select server_id from my_servers)),
    'channels', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.my_visible_server_channels() c),
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
$function$
;

CREATE OR REPLACE FUNCTION public.channel_messages(cid uuid, before timestamp with time zone DEFAULT NULL::timestamp with time zone, lim integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with msgs as (
    select m.* from public.messages m
    where m.channel_id = cid and public.can_access_channel(cid) and public.channel_history_ok(cid) and (before is null or m.created_at < before)
    order by m.created_at desc
    limit least(greatest(coalesce(lim, 50), 1), 100)
  )
  select jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from msgs m),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from (
      select id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
             avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge, verify_required, profile_effect, custom_status, avatar_deco, discriminator, name_style
      from public.profiles where id in (select author_id from msgs)) p),
    'reactions', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'message_id', r.message_id, 'user_id', r.user_id, 'emoji', r.emoji)), '[]'::jsonb)
      from public.reactions r where r.message_id in (select id from msgs))
  );
$function$
;

reset lock_timeout;
