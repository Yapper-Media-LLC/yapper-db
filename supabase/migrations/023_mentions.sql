-- ============================================================
-- Yapper · @mentions
-- Messages store mentions as <@user id>. unread_counts now also says how
-- many unread messages mention you, so muted chats can still show "@".
-- ============================================================
-- A new function (old tabs still call unread_counts until they refresh).
create or replace function public.unread_counts_v2()
returns table (channel_id uuid, unread int, muted boolean, mentions int)
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select cm.channel_id, cm.joined_at as since from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at from public.channels c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text' and public.can_access_channel(c.id)
  ),
  fresh as (
    select mine.channel_id, m.content
    from mine
    left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid()
    join lateral (
      select content from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > coalesce(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) m on true
  )
  select
    mine.channel_id,
    (select count(*)::int from fresh f where f.channel_id = mine.channel_id),
    coalesce(r.muted, false),
    (select count(*)::int from fresh f where f.channel_id = mine.channel_id
       and (f.content like '%<@' || auth.uid()::text || '>%' or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'))
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid();
$$;
grant execute on function public.unread_counts_v2() to authenticated;

-- Let a banned tab notice its unban straight away.
alter publication supabase_realtime add table public.site_bans;
