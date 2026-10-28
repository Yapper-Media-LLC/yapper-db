-- 409: search filters (flag chat_ux3): has:link / image / video / file, before:date and after:date, in:#channel.
-- search_messages_v3 is search_messages_v2 (298, as patched by 331 for taken-down servers: that patch is re-applied
-- below) with two more arguments: since (nothing older) and has (only that kind). The branches are v2's, each with
-- the two predicates added; a kind with no words and no author lists the newest of that kind in the chats you can
-- see (a server or one chat, like author alone). The client falls back to v2 while this isn't applied.
-- search_has: immutable, so it can sit in a where clause next to the text index.
-- Indexes for the kind-only search, built by hand BEFORE this (concurrently, so writes on messages aren't blocked;
-- a plain create index in a migration would lock the table), in quiet hours:
--   create index concurrently if not exists messages_attach_idx on public.messages (channel_id, created_at desc) where attachment_path is not null;
--   create index concurrently if not exists messages_link_idx on public.messages (channel_id, created_at desc) where strpos(content, 'http') > 0;
-- Re-runnable.
create or replace function public.search_has(content text, path text, kind text)
returns boolean
language sql
immutable
as $$
  select case kind
    when 'link' then coalesce(content, '') ~* 'https?://'
    when 'image' then coalesce(path, '') ~* '\.(png|jpe?g|gif|webp|avif)(\?|$)'
    when 'video' then coalesce(path, '') ~* '\.(mp4|webm|mov|m4v)(\?|$)'
    when 'file' then path is not null
    else true
  end;
$$;
revoke execute on function public.search_has(text, text, text) from public, anon;
grant execute on function public.search_has(text, text, text) to authenticated;

create or replace function public.search_messages_v3(q text, sid uuid default null, cid uuid default null, author uuid default null, before timestamptz default null, since timestamptz default null, has text default null)
returns setof public.messages
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  qq text := left(nullif(btrim(coalesce(q, '')), ''), 200);
  upto timestamptz := coalesce(before, 'infinity');
  after_at timestamptz := coalesce(since, '-infinity');
  kind text := nullif(btrim(coalesce(has, '')), '');
  me_on boolean;
  chans uuid[];
begin
  if auth.uid() is null or (qq is null and author is null and kind is null) or public.is_site_banned(auth.uid()) then
    return;
  end if;
  if kind is not null and kind not in ('link', 'image', 'video', 'file') then
    return;
  end if;
  -- Something that isn't a word search needs a place to look in (a server or one chat), like author alone did.
  if qq is null and sid is null and cid is null then
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
      and not exists (select 1 from public.servers sd where sd.id = c.server_id and sd.shut_down_at is not null and not public.is_staff())
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

  -- A kind with no words and no author: the newest 50 of that kind per channel, then the newest 50 of those (the
  -- shape v2 uses for author-only, so a channel with plenty stops after 50 rows). The literal predicates let the
  -- planner use the partial indexes messages_attach_idx / messages_link_idx (built by hand, see the header).
  if qq is null and author is null then
    if kind = 'link' then
      return query
      with top as (
        select t.id, t.created_at
        from unnest(chans) as ch(id)
        cross join lateral (
          select m1.id, m1.created_at from public.messages m1
          where m1.channel_id = ch.id and m1.created_at < upto and m1.created_at > after_at
            and strpos(m1.content, 'http') > 0 and public.search_has(m1.content, m1.attachment_path, kind)
          order by m1.created_at desc
          limit 50
        ) t
        order by t.created_at desc
        limit 50
      )
      select m.*
      from top t
      join public.messages m on m.id = t.id
      order by m.created_at desc
      limit 50;
    else
      return query
      with top as (
        select t.id, t.created_at
        from unnest(chans) as ch(id)
        cross join lateral (
          select m1.id, m1.created_at from public.messages m1
          where m1.channel_id = ch.id and m1.created_at < upto and m1.created_at > after_at
            and m1.attachment_path is not null and public.search_has(m1.content, m1.attachment_path, kind)
          order by m1.created_at desc
          limit 50
        ) t
        order by t.created_at desc
        limit 50
      )
      select m.*
      from top t
      join public.messages m on m.id = t.id
      order by m.created_at desc
      limit 50;
    end if;
  elsif qq is null then
    return query
      with top as (
        select t.channel_id, t.created_at
        from unnest(chans) as ch(id)
        cross join lateral (
          select m1.channel_id, m1.created_at from public.messages m1
          where m1.channel_id = ch.id and m1.author_id = author and m1.created_at < upto and m1.created_at > after_at and public.search_has(m1.content, m1.attachment_path, kind)
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
          and m1.created_at < upto and m1.created_at > after_at and public.search_has(m1.content, m1.attachment_path, kind)
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
          and m1.created_at < upto and m1.created_at > after_at and public.search_has(m1.content, m1.attachment_path, kind)
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
          and m1.created_at < upto and m1.created_at > after_at and public.search_has(m1.content, m1.attachment_path, kind)
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

revoke execute on function public.search_messages_v3(text, uuid, uuid, uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.search_messages_v3(text, uuid, uuid, uuid, timestamptz, timestamptz, text) to authenticated;
