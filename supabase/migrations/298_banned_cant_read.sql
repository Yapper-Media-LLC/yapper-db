set lock_timeout = '3s';
-- 298: a site-banned account can't read any chat. The app swaps to the ban screen, but the messages policy and the
-- realtime server both ask can_access_channel, which never looked at bans: going back in the browser brought the old
-- page back and its fetches and live updates still worked (WealdyStony, Oct 19). Ban appeals, standing, upload
-- appeals, data export and account deletion don't go through any of this. Every body below is the live definition
-- (pg_get_functiondef, Oct 19) with only the ban check added:
--   can_access_channel        message reads, realtime chan: subscribe, reports
--   visible_server_channels   search and mentions in servers, the channel list reload (also my_visible_server_channels).
--                             bootstrap's visible_server_channels_fast still lists names and unread counts: no content.
--   my_mentions               its DM branch
--   search_messages_v2        returns nothing for a banned caller
--   broadcast_message_change  no live DM copies or pings to banned members
-- Re-runnable.

create or replace function public.can_access_channel(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    not public.is_site_banned(auth.uid())
    and (
      public.is_channel_member(cid)
      or exists (
        select 1 from public.channels c
        where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
          and case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                                and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                    and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
            then public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
            else (
              not c.private
              or public.server_perm(c.server_id, 'manage_server')
              or exists (
                select 1 from public.channel_roles cr
                join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
                where cr.channel_id = c.id
              )
              or exists (select 1 from public.channel_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
              or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
            ) end
      )
    );
$$;

create or replace function public.visible_server_channels(sids uuid[])
returns setof public.channels
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select sm.server_id, sm.joined_at, public.server_perm(sm.server_id, 'manage_server') as mg,
           exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and sm.server_id = any(f.servers)))) as cp
    from public.server_members sm
    where sm.user_id = auth.uid() and (sids is null or sm.server_id = any(sids))
      and not public.is_site_banned(auth.uid())
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
$$;

create or replace function public.my_mentions(lim integer default 40)
returns setof public.messages
language sql
stable
security definer
set search_path = public
as $$
  with pings as materialized (select * from public.my_role_pings()),
  chans as materialized (
    select cm.channel_id, null::uuid as sid, cm.joined_at as since
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where cm.user_id = (select auth.uid()) and not public.is_site_banned((select auth.uid()))
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

create or replace function public.search_messages_v2(q text, sid uuid default null, cid uuid default null, author uuid default null, before timestamptz default null)
returns setof public.messages
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  qq text := left(nullif(btrim(coalesce(q, '')), ''), 200);
  upto timestamptz := coalesce(before, 'infinity');
  me_on boolean;
  chans uuid[];
begin
  if auth.uid() is null or (qq is null and author is null) or public.is_site_banned(auth.uid()) then
    return;
  end if;
  if author is not null and sid is null and cid is null then
    return;
  end if;
  if qq is not null and querytree(websearch_to_tsquery('simple', qq)) in ('T', '') then
    return;
  end if;

  me_on := public.feature_on_for_me('search');
  select coalesce(array_agg(x.id), '{}') into chans from (
    select c.id
    from public.visible_server_channels(case when sid is null then null else array[sid] end) c
    where (cid is null or c.id = cid)
      and (c.kind = 'text' or (c.kind = 'voice' and public.feature_on('voice_chat', c.server_id)))
      and (me_on or public.feature_on('search', c.server_id))
      and public.channel_history_ok(c.id)
    union
    select cm.channel_id
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where me_on and sid is null and cm.user_id = auth.uid() and (cid is null or cm.channel_id = cid)
  ) x;
  if cardinality(chans) = 0 then
    return;
  end if;

  if qq is null then
    return query
      with top as (
        select t.channel_id, t.created_at
        from unnest(chans) as ch(id)
        cross join lateral (
          select m1.channel_id, m1.created_at from public.messages m1
          where m1.channel_id = ch.id and m1.author_id = author and m1.created_at < upto
          order by m1.created_at desc
          limit 50
        ) t
        group by t.channel_id, t.created_at
        order by t.created_at desc
        limit 50
      )
      select m.*
      from top t
      join public.messages m on m.channel_id = t.channel_id and m.author_id = author and m.created_at = t.created_at
      order by m.created_at desc
      limit 50;
  elsif author is null and sid is null then
    return query
      with hits as materialized (
        select m1.id, m1.channel_id, m1.created_at
        from public.messages m1
        where (cid is null or m1.channel_id = cid)
          and m1.created_at < upto
          and to_tsvector('simple', coalesce(m1.content, '')) @@ websearch_to_tsquery('simple', qq)
        order by m1.created_at desc
        limit 5000
      )
      select m.*
      from hits h
      join public.messages m on m.id = h.id
      where h.channel_id = any(chans)
      order by h.created_at desc
      limit 50;
  elsif author is null then
    return query
      with hits as materialized (
        select m1.id, m1.created_at
        from public.messages m1
        where m1.channel_id = any(chans)
          and m1.created_at < upto
          and to_tsvector('simple', coalesce(m1.content, '')) @@ websearch_to_tsquery('simple', qq)
        order by m1.created_at desc
        limit 5000
      )
      select m.*
      from hits h
      join public.messages m on m.id = h.id
      order by h.created_at desc
      limit 50;
  else
    return query
      with hits as materialized (
        select m1.id, m1.created_at
        from public.messages m1
        where m1.channel_id = any(chans)
          and m1.author_id = author
          and m1.created_at < upto
          and to_tsvector('simple', coalesce(m1.content, '')) @@ websearch_to_tsquery('simple', qq)
        order by m1.created_at desc
        limit 5000
      )
      select m.*
      from hits h
      join public.messages m on m.id = h.id
      order by h.created_at desc
      limit 50;
  end if;
end;
$$;

create or replace function public.broadcast_message_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid; sid uuid; uid uuid; o public.messages;
  body text; targets uuid[]; open_ boolean; vis boolean; old_claims text; old_sub text;
  uuid_re constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if current_setting('yapper.bulk', true) = '1' then return null; end if;
  cid := coalesce(new.channel_id, old.channel_id);
  if tg_op = 'DELETE' then
    o := jsonb_populate_record(null::public.messages, jsonb_build_object('id', old.id, 'channel_id', old.channel_id, 'author_id', old.author_id));
  else
    o := old;
  end if;
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform public.bc('chan:' || cid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
    body := coalesce(new.content, '');
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
        select not coalesce(ch.private, false)
               and not exists (select 1 from public.channel_overrides ov where ov.channel_id = ch.id or (ch.category_id is not null and ov.category_id = ch.category_id))
          into open_ from public.channels ch where ch.id = cid;
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
reset lock_timeout;
