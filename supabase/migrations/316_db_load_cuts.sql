-- 316: database load cuts (Supabase support, Oct 19: XL compute at 60-100% CPU from query work).
-- Re-runnable. One apply, before 14:00 UTC (DDL reloads both PostgRESTs).
--
-- 1. bootstrap_fast: role assignments looked up by role (only roles that aren't automatic) instead of reading every
--    assignment of every server and throwing the automatic ones away (26k rows read to keep 1.7k: 33-69 ms of each
--    start-up). Hand-given automatic roles (manual_auto_roles) are now included too, as loadServers already did.
--    Flag lazy_boot: members of small servers no longer come with full profiles (the member list asks for the ones
--    it shows, from the realtime server's shared profile cache, like big servers already do).
-- 2. server_role_assignments(sids): everything loadServers / refreshRoles need about role assignments in one call
--    (was an exact count query plus OFFSET pages of 1000 plus manual_auto_roles).
-- 3. find_server_members(sid, q, with_display): member search as an indexed prefix match on lower(username)
--    (and, flag member_search_names, lower(display_name)), like Discord. The old ilike join read up to 319k buffers.
--    Servers up to 2000 members: walk the members instead (bounded, whatever the prefix).
-- 4. user_id_by_username(name): exact, case-insensitive username -> id on the unique lower(username) index.
--    ilike without wildcards can't use an index. Counted by the username lookup limit (308) like profiles?username=.
-- 5. Live unread badges (flag live_badges): every new or deleted message in a server with the flag also sends a small
--    notice (no content) on server:<id>. The realtime server passes notices for private / overridden channels only to people
--    who can see that channel. The app counts badges from these instead of polling unread_counts_v2 every 3 minutes.

-- ---------- 1. bootstrap_fast ----------
create or replace function public.bootstrap_fast()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  vis public.channels[] := array(select c from public.visible_server_channels_fast(null) c);
  lazy boolean := public.feature_on_for_me('lazy_boot');
begin
  return (
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
    select server_id from members where not lazy group by server_id having count(*) <= 300
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
  ),
  -- 316: manual (not automatic) roles first, then their assignments by role_id; plus automatic roles given by hand.
  plain_roles as (
    select r.id from public.roles r
    where r.server_id in (select server_id from my_servers) and coalesce(r.auto, 'none') = 'none'
  ),
  assigned as (
    select mr.server_id, mr.user_id, mr.role_id from public.member_roles mr
    join plain_roles pr on pr.id = mr.role_id -- same server: FK (role_id, server_id)
    union
    select mr.server_id, mr.user_id, mr.role_id from public.member_roles mr
    where mr.manual and mr.server_id in (select server_id from my_servers)
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
    'channels', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from unnest(vis) c),
    'channel_roles', (select coalesce(jsonb_agg(jsonb_build_array(channel_id, role_id)), '[]'::jsonb) from public.channel_roles where server_id in (select server_id from my_servers)),
    'post_roles', (select coalesce(jsonb_agg(jsonb_build_array(channel_id, role_id)), '[]'::jsonb) from public.channel_post_roles where server_id in (select server_id from my_servers)),
    'roles', (select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from public.roles r where r.server_id in (select server_id from my_servers)),
    'member_roles', (select coalesce(jsonb_agg(jsonb_build_array(a.server_id, a.user_id, a.role_id)), '[]'::jsonb) from assigned a),
    'members', (select coalesce(jsonb_object_agg(server_id, arr), '{}'::jsonb) from (
      select server_id, jsonb_agg(case when nickname is null then jsonb_build_array(user_id, extract(epoch from joined_at)::bigint)
                                       else jsonb_build_array(user_id, extract(epoch from joined_at)::bigint, nickname) end) as arr
      from members group by server_id) x),
    'member_counts', (select coalesce(jsonb_object_agg(server_id, n), '{}'::jsonb) from public.server_member_counts((select coalesce(array_agg(server_id), '{}'::uuid[]) from my_servers))),
    'friends', (select coalesce(jsonb_agg(jsonb_build_array(requester, addressee, status)), '[]'::jsonb) from fr),
    'blocks', (select coalesce(jsonb_agg(blocked), '[]'::jsonb) from bl),
    'dm_requests', (select coalesce(jsonb_agg(from_id), '[]'::jsonb) from dr),
    'unread', (select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) from public.unread_counts_for(vis) u),
    'server_mutes', (select coalesce(jsonb_agg(server_id), '[]'::jsonb) from public.server_mutes where user_id = auth.uid()),
    'flags', (select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) from public.my_flags() f),
    'emojis', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from public.emojis e where e.server_id in (select server_id from my_servers)),
    'categories', (select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb) from public.channel_categories k where k.server_id in (select server_id from my_servers)),
    'is_admin', exists (select 1 from public.site_admins where user_id = auth.uid()),
    'mod', (select to_jsonb(m) from (select suspended_at from public.site_moderators where user_id = auth.uid()) m),
    'ban', (select to_jsonb(b) from (select reason, created_at, expires_at from public.site_bans where user_id = auth.uid()) b)
  ));
end
$function$;
revoke execute on function public.bootstrap_fast() from public, anon, authenticated, service_role;

-- ---------- 2. server_role_assignments ----------
-- [[server_id, user_id, role_id], ...] for the servers asked about that I'm in: assignments of roles that aren't
-- automatic, plus automatic roles given by hand (member_roles.manual). One jsonb value, so PostgREST's 1000-row cap
-- doesn't apply and no paging is needed.
create or replace function public.server_role_assignments(sids uuid[])
returns jsonb
language sql
stable security definer
set search_path = public
as $$
  with mine as (
    select sm.server_id from public.server_members sm
    where sm.user_id = (select auth.uid()) and sm.server_id = any(sids)
  ),
  plain_roles as (
    select r.id from public.roles r
    where r.server_id in (select server_id from mine) and coalesce(r.auto, 'none') = 'none'
  ),
  assigned as (
    select mr.server_id, mr.user_id, mr.role_id from public.member_roles mr
    join plain_roles pr on pr.id = mr.role_id -- same server: FK (role_id, server_id)
    union
    select mr.server_id, mr.user_id, mr.role_id from public.member_roles mr
    where mr.manual and mr.server_id in (select server_id from mine)
  )
  select coalesce(jsonb_agg(jsonb_build_array(a.server_id, a.user_id, a.role_id)), '[]'::jsonb) from assigned a;
$$;
revoke execute on function public.server_role_assignments(uuid[]) from public, anon;
grant execute on function public.server_role_assignments(uuid[]) to authenticated, service_role;

-- ---------- 3. find_server_members ----------
-- Members of a server I'm in whose username (or, with with_display, display name) starts with q, case-insensitive.
-- Small servers: walk the member list. Big ones: walk the prefix on the profiles indexes (lower(...) collate "C")
-- and keep members; stops after lim hits.
create or replace function public.find_server_members(sid uuid, q text, with_display boolean default false, lim int default 10)
returns table(user_id uuid, nickname text, joined_at timestamptz)
language plpgsql
stable security definer
set search_path = public
-- The prefix is a variable: a generic plan can't turn "like pat" into an index range.
set plan_cache_mode = force_custom_plan
as $$
declare
  pat text;
  n int;
begin
  if sid is null or q is null then return; end if;
  if not exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = (select auth.uid())) then return; end if;
  q := lower(btrim(q));
  if length(q) < 2 or length(q) > 64 then return; end if;
  lim := least(greatest(coalesce(lim, 10), 1), 25);
  pat := replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  select count(*) into n from (select 1 from public.server_members sm where sm.server_id = sid limit 2001) x;
  if n <= 2000 then
    return query
      select sm.user_id, sm.nickname, sm.joined_at
      from public.server_members sm
      join public.profiles p on p.id = sm.user_id
      where sm.server_id = sid
        and (lower(p.username) collate "C" like pat
             or (with_display and p.display_name is not null and lower(p.display_name) collate "C" like pat))
      order by lower(p.username) collate "C"
      limit lim;
    return;
  end if;
  return query
    select sm.user_id, sm.nickname, sm.joined_at
    from (
      (select p.id, lower(p.username) collate "C" as k from public.profiles p
        where lower(p.username) collate "C" like pat
          and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.id)
        order by lower(p.username) collate "C" limit lim)
      union
      (select p.id, lower(p.username) collate "C" from public.profiles p
        where with_display and p.display_name is not null and lower(p.display_name) collate "C" like pat
          and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.id)
        order by lower(p.display_name) collate "C" limit lim)
    ) hit
    join public.server_members sm on sm.server_id = sid and sm.user_id = hit.id
    order by hit.k
    limit lim;
end;
$$;
revoke execute on function public.find_server_members(uuid, text, boolean, int) from public, anon;
grant execute on function public.find_server_members(uuid, text, boolean, int) to authenticated, service_role;

-- ---------- 4. user_id_by_username ----------
create or replace function public.user_id_by_username(name text)
returns uuid
language sql
stable security definer
set search_path = public
as $$
  select p.id from public.profiles p
  where name is not null and length(name) between 1 and 64 and lower(p.username) = lower(btrim(name))
  limit 1;
$$;
revoke execute on function public.user_id_by_username(text) from public, anon;
grant execute on function public.user_id_by_username(text) to authenticated, service_role;

-- ---------- 5. live unread badges ----------
-- Like bc(), with a payload built by the caller (bc() sends whole rows). Only for our realtime server (rt_mode vps
-- or both); Supabase Realtime never carried these.
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare mode text; url text; secret text;
begin
  select rt_mode into mode from public.app_settings limit 1;
  if coalesce(mode, 'supabase') not in ('both', 'vps') then return; end if;
  select decrypted_secret into url from vault.decrypted_secrets where name = 'rt_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'rt_secret';
  if url is null or secret is null then return; end if;
  perform net.http_post(
    url := url || '/publish',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret),
    body := jsonb_build_object('topic', topic_name, 'event', event_name, 'payload', payload),
    timeout_milliseconds := 3000);
end; $$;
revoke execute on function public.bc_notice(text, text, jsonb) from public, anon, authenticated;

create or replace function public.broadcast_message_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid; sid uuid; uid uuid; o public.messages;
  body text; targets uuid[]; open_ boolean; vis boolean; restricted boolean; old_claims text; old_sub text;
  uuid_re constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if current_setting('yapper.bulk', true) = '1' then return null; end if;
  cid := coalesce(new.channel_id, old.channel_id);
  if tg_op = 'DELETE' then
    o := jsonb_populate_record(null::public.messages, jsonb_build_object('id', old.id, 'channel_id', old.channel_id, 'author_id', old.author_id));
  else
    o := old;
  end if;
  -- 316: restricted = private, or overrides on it or its category (the same test the pings below use).
  select ch.server_id,
         coalesce(ch.private, false)
         or exists (select 1 from public.channel_overrides ov where ov.channel_id = ch.id or (ch.category_id is not null and ov.category_id = ch.category_id))
    into sid, restricted from public.channels ch where ch.id = cid;
  restricted := coalesce(restricted, true);
  open_ := not restricted;
  if sid is not null then
    perform public.bc('chan:' || cid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
    body := coalesce(new.content, '');
    -- 316: everyone in the server hears that a message came or went (no content), for the unread badges (flag
    -- live_badges: everyone, or the servers listed in test). The realtime server only passes restricted ones on to
    -- people who can see the channel.
    if tg_op in ('INSERT', 'DELETE') and exists (
         select 1 from public.feature_flags f
         where f.key = 'live_badges' and (f.mode = 'everyone' or (f.mode = 'test' and sid = any(f.servers)))) then
      perform public.bc_notice('server:' || sid, 'unread', jsonb_build_object(
        'operation', tg_op,
        'id', coalesce(new.id, old.id),
        'channel_id', cid,
        'author_id', coalesce(new.author_id, old.author_id),
        'created_at', coalesce(new.created_at, old.created_at),
        'everyone', tg_op = 'INSERT' and not starts_with(body, chr(8618) || ' Forwarded' || chr(10)) and body ~ '(^|[^A-Za-z0-9_@])@everyone\M',
        'restricted', restricted));
    end if;
    if tg_op = 'INSERT' and not starts_with(body, chr(8618) || ' Forwarded' || chr(10))
       and (strpos(body, '<@') > 0 or new.reply_to_id is not null) then
      select array_agg(distinct t.x) into targets from (
        (select m[1]::uuid as x from regexp_matches(body, '<@(' || uuid_re || ')>', 'g') m limit 20)
        union all
        (select mr.user_id from public.member_roles mr
          where mr.server_id = sid
            and mr.role_id in (select m[1]::uuid from regexp_matches(body, '<@&(' || uuid_re || ')>', 'g') m limit 10)
          limit 50)
        union all
        (select pm.author_id from public.messages pm where new.reply_to_id is not null and pm.id = new.reply_to_id and pm.channel_id = cid)
      ) t
      where t.x is not null and t.x is distinct from new.author_id;
      if targets is not null then
        -- open_ was worked out above (316) with the same test.
        old_claims := current_setting('request.jwt.claims', true);
        old_sub := current_setting('request.jwt.claim.sub', true);
        foreach uid in array targets loop
          if not exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = uid) then continue; end if;
          -- 298: banned people get no pings (open channels skip the access check below).
          if public.is_site_banned(uid) then continue; end if;
          if not coalesce(open_, false) then
            perform set_config('request.jwt.claims', jsonb_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
            perform set_config('request.jwt.claim.sub', uid::text, true);
            vis := public.can_access_channel(cid);
            perform set_config('request.jwt.claims', coalesce(nullif(old_claims, ''), '{}'), true);
            perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
            if not coalesce(vis, false) then continue; end if;
          end if;
          perform public.bc('user:' || uid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
        end loop;
      end if;
    end if;
  else
    -- 298: and no live copies of DMs or group messages while banned.
    for uid in select cm.user_id from public.channel_members cm where cm.channel_id = cid and not public.is_site_banned(cm.user_id) loop
      perform public.bc('user:' || uid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
    end loop;
  end if;
  return null;
end; $$;

-- ---------- flags (test: Antic and the "test" server) ----------
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('live_badges', 'Live unread badges', 'Unread badges for every channel update the moment a message arrives, without polling', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}'),
  ('lazy_boot', 'Lighter start-up', 'Start-up skips full profiles of small servers'' members; they load when shown', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}'),
  ('member_search_names', 'Member search by display name', 'Searching a server''s members also matches the start of display names', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
