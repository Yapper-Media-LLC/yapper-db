-- Mentions inbox: only pings from after you joined the chat or server. Joining a server used to
-- show its old @everyone / role pings from before you were there (even from before your account
-- existed). Same shape as 146 (one probe per channel on messages_pingy_idx, the WHERE repeats the
-- index predicate), with a per-channel "since" bound on created_at.
create or replace function public.my_mentions(lim integer default 40)
returns setof public.messages language sql stable security definer set search_path = public as $$
  with pings as materialized (select * from public.my_role_pings()),
  chans as materialized (
    select cm.channel_id, null::uuid as sid, cm.joined_at as since
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where cm.user_id = (select auth.uid())
    union all
    select v.id, v.server_id, sm.joined_at
    from public.my_visible_server_channels() v
    join public.server_members sm on sm.server_id = v.server_id and sm.user_id = (select auth.uid())
  )
  select m.*
  from chans
  left join pings p on p.sid = chans.sid
  cross join lateral (
    select x.* from public.messages x
    where x.channel_id = chans.channel_id
      and (strpos(x.content, '<@') > 0 or strpos(x.content, '@everyone') > 0)
      and x.created_at > greatest(now() - interval '30 days', coalesce(chans.since, now() - interval '30 days'))
      and x.author_id <> (select auth.uid())
      and (x.content like '%<@' || (select auth.uid())::text || '>%'
           or x.content ~ '(^|[^\w])@everyone([^\w]|$)'
           or (p.pats is not null and strpos(x.content, '<@&') > 0 and x.content like any (p.pats)))
    order by x.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  ) m
  order by m.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$$;
revoke all on function public.my_mentions(integer) from public, anon;
grant execute on function public.my_mentions(integer) to authenticated;
