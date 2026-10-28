-- 240: search by person (flag search_from, test). Like Discord's "from:" filter, for modding.
-- search_messages_v2(q, sid, cid, author, before): a new function next to search_messages (old clients keep
-- calling that one, unchanged). Which channels it looks in:
--   * server channels: visible_server_channels (the set-based view check the channel list uses), text (or voice
--     with voice_chat on), search flag on, and channel_history_ok (no "read history", no results);
--   * DMs and groups (channels with no server only) I'm in, when no server is picked and search is on for me.
--     Server channels I'm linked to through channel_members (tickets, bots) go through the server checks above.
-- Limits: q is cut to 200 characters; a q the word index can't use (only negations, like "-hello", or no words
-- at all, like "!!") finds nothing;
-- a person filter needs a server or a channel (the app always sends one).
-- Modes:
--   * author only (q empty): per accessible channel, the newest 50 (channel_id, created_at) of theirs straight from
--     messages_channel_author_idx (index-only), the newest 50 of those overall, then those messages;
--   * q only: the word-index search; with a server picked, already narrowed to my channels in it (so the 5000 cap
--     isn't used up by other servers); without one, exactly the live search;
--   * q + author: narrowed to them and my channels first (the planner walks messages_channel_author_idx, ~50ms
--     for a big server's top poster);
--   * neither: nothing.
-- "before" pages back: only messages older than it (pass the oldest created_at shown). Re-runnable.

create or replace function public.search_messages_v2(q text, sid uuid default null, cid uuid default null,
  author uuid default null, before timestamptz default null)
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
  if auth.uid() is null or (qq is null and author is null) then
    return;
  end if;
  -- A person filter always comes with a server or a channel.
  if author is not null and sid is null and cid is null then
    return;
  end if;
  -- Only negations ("-hello") can't use the word index: it would read every message. Nothing to look for ("!!"): nothing.
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
    -- Everything this person said, newest first: a short index-only walk per channel, then the 50 newest overall.
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
    -- The live search: the word index finds matches everywhere fast; the newest few thousand are plenty.
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
    -- One server: only my channels in it count toward the cap, so busy servers elsewhere can't crowd it out.
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
    -- Words from one person: narrowed to them and my channels before the cap.
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

revoke all on function public.search_messages_v2(text, uuid, uuid, uuid, timestamptz) from public, anon;
grant execute on function public.search_messages_v2(text, uuid, uuid, uuid, timestamptz) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('search_from', 'Search by person', 'Search filter for one person''s messages (from:), plus Load more in search.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
