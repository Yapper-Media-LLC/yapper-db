-- 199: the two heaviest queries behind the Oct 17 lag (DB at ~3.5 of 4 cores).
--
-- 1. unread_counts_v2 counted each channel's unread messages by scanning the whole "fresh" list once per
--    channel (channels x fresh messages): 2.3 s for someone in 150 servers, and it runs on every start-up
--    (bootstrap) and badge refresh. Now each channel counts its own messages in the lateral that finds them.
--    Same output, checked against the old function on a live 150-server account (0 differing rows), ~5x faster.
-- 2. The app loaded server channels with a plain select on channels, so the "see channels you can access"
--    policy ran can_access_channel() once per row: 1.6 s for 1,700 channels. visible_server_channels(sids)
--    is the set-based check my_visible_server_channels() already did (0.23 s for the same account), limited
--    to the given servers. my_visible_server_channels() now calls it, so the visibility rules live in one place.
-- Re-runnable.

create or replace function public.visible_server_channels(sids uuid[])
returns setof public.channels
language sql
stable
security definer
set search_path to 'public'
as $function$
  with mine as (
    select sm.server_id, sm.joined_at, public.server_perm(sm.server_id, 'manage_server') as mg,
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
$function$;
revoke all on function public.visible_server_channels(uuid[]) from public, anon;
grant execute on function public.visible_server_channels(uuid[]) to authenticated, service_role;

create or replace function public.my_visible_server_channels()
returns setof public.channels
language sql
stable
security definer
set search_path to 'public'
as $function$
  select * from public.visible_server_channels(null);
$function$;

create or replace function public.unread_counts_v2()
returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
language sql
stable
security definer
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
                              or (p.pats is not null and strpos(f.content, '<@&') > 0 and f.content like any (p.pats))))::int as mentions
    from (
      select m.content from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > coalesce(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) f
  ) x on true;
$function$;

notify pgrst, 'reload schema';
