-- 268: lighter start-up (bootstrap) and unread badges (unread_counts_v2), behind flag `fast_startup`.
-- Why (Oct 18): the two were ~35% of all database time, and at the evening peak bootstrap took 0.8 s instead of 0.2 s.
-- Three changes, same results (checked live against the old functions for several accounts):
--   1. plpgsql instead of sql: Postgres 17 re-plans a non-inlined sql function on every call (18-26 ms each here);
--      plpgsql keeps the plan for the connection.
--   2. visible_server_channels: `mine` is materialized, so server_perm(manage_server) runs once per server instead of
--      once per channel (103 calls instead of 3 for an HQ member), and only in servers that have a private channel.
--   3. bootstrap works out the visible channels once and hands them to the unread counts (it did it twice).
-- bootstrap() and unread_counts_v2() keep their names and results (the app doesn't change) and become switches:
-- flag on -> the fast versions, off -> bootstrap_v1 / unread_counts_v1, which are the live functions copied verbatim
-- except one line: bootstrap_v1 calls unread_counts_v1 directly (not the unread_counts_v2 switch), so flag off costs
-- the same as before.
-- After turning it on: check pg_stat_statements for bootstrap / unread_counts_v2. If the plpgsql generic plan for
-- unnest(vis) goes bad, add `set plan_cache_mode = force_custom_plan` to unread_counts_for.
-- The new helpers are internal: unread_counts_for(vis) trusts its channel list, so nobody but these functions may call it.
-- Rollback: flag off. Publish: mode everyone. Re-runnable.

-- ---------- the current versions, verbatim, under new names ----------
-- (unread_counts_v1 first: bootstrap_v1 is plain sql, so its body is checked when it's created.)

create or replace function public.unread_counts_v1()
returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
language sql
stable security definer
set search_path to 'public'
as $function$
  with pings as materialized (select * from public.my_role_pings()),
  vc as materialized (
    select f.mode, f.servers, f.users from public.feature_flags f where f.key = 'voice_chat'
  ),
  mine as materialized (
    select cm.channel_id, cm.joined_at as since, null::uuid as sid from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at, c.server_id from public.my_visible_server_channels() c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text'
       or (c.kind = 'voice' and exists (select 1 from vc where vc.mode = 'everyone'
             or (vc.mode = 'test' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users))))
             and (not public.channel_overrides_live(c.id) or public.channel_perm(c.id, 'connect')))
  )
  select
    mine.channel_id,
    coalesce(x.unread, 0),
    coalesce(r.muted, false),
    coalesce(x.mentions, 0)
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid()
  left join pings p on p.sid = mine.sid
  left join lateral (
    select count(*)::int as unread,
           (count(*) filter (where f.content like '%<@' || auth.uid()::text || '>%'
                              or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
                              or (p.pats is not null and strpos(f.content, '<@&') > 0 and f.content like any (p.pats))
                              or (f.reply_to_id is not null
                                  and exists (select 1 from public.messages pm where pm.id = f.reply_to_id and pm.author_id = (select auth.uid())))))::int as mentions
    from (
      select m.content, m.reply_to_id from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > coalesce(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) f
  ) x on true;
$function$;

create or replace function public.bootstrap_v1()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
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
    'unread', (select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) from public.unread_counts_v1() u),
    'server_mutes', (select coalesce(jsonb_agg(server_id), '[]'::jsonb) from public.server_mutes where user_id = auth.uid()),
    'flags', (select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) from (select key, label, description, mode, servers, users from public.feature_flags) f),
    'emojis', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from public.emojis e where e.server_id in (select server_id from my_servers)),
    'categories', (select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb) from public.channel_categories k where k.server_id in (select server_id from my_servers)),
    'is_admin', exists (select 1 from public.site_admins where user_id = auth.uid()),
    'mod', (select to_jsonb(m) from (select suspended_at from public.site_moderators where user_id = auth.uid()) m),
    'ban', (select to_jsonb(b) from (select reason, created_at, expires_at from public.site_bans where user_id = auth.uid()) b)
  );
$function$;

-- ---------- the fast versions ----------

-- visible_server_channels with `mine` materialized (server_perm once per server, not per channel), in plpgsql.
create or replace function public.visible_server_channels_fast(sids uuid[])
returns setof public.channels
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  return query
  with mine as materialized (
    -- mg is only read for private channels, so servers without any skip the permission check.
    select sm.server_id, sm.joined_at,
           case when exists (select 1 from public.channels x where x.server_id = sm.server_id and x.private)
                then public.server_perm(sm.server_id, 'manage_server') else false end as mg,
           exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and sm.server_id = any(f.servers)))) as cp
    from public.server_members sm
    where sm.user_id = auth.uid() and (sids is null or sm.server_id = any(sids))
  ),
  st as (select public.is_staff() as s)
  select c.*
  from public.channels c
  join mine on mine.server_id = c.server_id
  where case when mine.cp and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) then
      exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
      or public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
    else (
      not c.private
     or mine.mg
     or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
     or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid() where cr.channel_id = c.id)
     or exists (select 1 from public.channel_roles cr join public.roles r on r.id = cr.role_id
                where cr.channel_id = c.id
                  and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and mine.joined_at < r.auto_before)))
     or ((select s from st) and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
    ) end;
end
$function$;

-- unread_counts_v1 over a channel list worked out by the caller (must be visible_server_channels_fast for this user).
create or replace function public.unread_counts_for(vis public.channels[])
returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return query
  with pings as materialized (select * from public.my_role_pings()),
  vc as materialized (
    select f.mode, f.servers, f.users from public.feature_flags f where f.key = 'voice_chat'
  ),
  mine as materialized (
    select cm.channel_id, cm.joined_at as since, null::uuid as sid from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at, c.server_id from unnest(vis) c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text'
       or (c.kind = 'voice' and exists (select 1 from vc where vc.mode = 'everyone'
             or (vc.mode = 'test' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users))))
             and (not public.channel_overrides_live(c.id) or public.channel_perm(c.id, 'connect')))
  )
  select
    mine.channel_id,
    coalesce(x.unread, 0),
    coalesce(r.muted, false),
    coalesce(x.mentions, 0)
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid()
  left join pings p on p.sid = mine.sid
  left join lateral (
    select count(*)::int as unread,
           (count(*) filter (where f.content like '%<@' || auth.uid()::text || '>%'
                              or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
                              or (p.pats is not null and strpos(f.content, '<@&') > 0 and f.content like any (p.pats))
                              or (f.reply_to_id is not null
                                  and exists (select 1 from public.messages pm where pm.id = f.reply_to_id and pm.author_id = (select auth.uid())))))::int as mentions
    from (
      select m.content, m.reply_to_id from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > coalesce(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) f
  ) x on true;
end
$function$;

-- bootstrap_v1 with the visible channels worked out once, for both 'channels' and 'unread'.
create or replace function public.bootstrap_fast()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  vis public.channels[] := array(select c from public.visible_server_channels_fast(null) c);
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
    'channels', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from unnest(vis) c),
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
    'unread', (select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) from public.unread_counts_for(vis) u),
    'server_mutes', (select coalesce(jsonb_agg(server_id), '[]'::jsonb) from public.server_mutes where user_id = auth.uid()),
    'flags', (select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) from (select key, label, description, mode, servers, users from public.feature_flags) f),
    'emojis', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from public.emojis e where e.server_id in (select server_id from my_servers)),
    'categories', (select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb) from public.channel_categories k where k.server_id in (select server_id from my_servers)),
    'is_admin', exists (select 1 from public.site_admins where user_id = auth.uid()),
    'mod', (select to_jsonb(m) from (select suspended_at from public.site_moderators where user_id = auth.uid()) m),
    'ban', (select to_jsonb(b) from (select reason, created_at, expires_at from public.site_bans where user_id = auth.uid()) b)
  ));
end
$function$;

-- Internal: only the two switches below (security definer, owner postgres) call these.
revoke execute on function public.bootstrap_v1() from public, anon, authenticated, service_role;
revoke execute on function public.unread_counts_v1() from public, anon, authenticated, service_role;
revoke execute on function public.visible_server_channels_fast(uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.unread_counts_for(public.channels[]) from public, anon, authenticated, service_role;
revoke execute on function public.bootstrap_fast() from public, anon, authenticated, service_role;

-- ---------- the switches (same names, arguments and results as before) ----------

create or replace function public.bootstrap()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if public.feature_on_for_me('fast_startup') then
    return public.bootstrap_fast();
  end if;
  return public.bootstrap_v1();
end
$function$;

create or replace function public.unread_counts_v2()
returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if public.feature_on_for_me('fast_startup') then
    return query select * from public.unread_counts_for(array(select c from public.visible_server_channels_fast(null) c));
    return;
  end if;
  return query select * from public.unread_counts_v1();
end
$function$;

-- Unchanged access to the two entry points (create or replace keeps grants; stated here so a fresh run matches live).
revoke execute on function public.bootstrap() from public, anon;
revoke execute on function public.unread_counts_v2() from public, anon;
grant execute on function public.bootstrap() to authenticated, service_role;
grant execute on function public.unread_counts_v2() to authenticated, service_role;

-- Test mode: Antic and the "test" server (2 members).
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('fast_startup', 'Faster start-up', 'Lighter start-up and unread badge queries. Same results, less database work', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
