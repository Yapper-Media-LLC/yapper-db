-- 675: more search filters (flag search_filters, test): mentions:user, pinned:true, has:embed / sound / poll, on top of
-- 409's from:, in:, has:link / image / video / file, before: and after: (during:date is before + after, client side).
-- search_messages_v4 = search_messages_v3 (409) plus two arguments: mention (only messages with <@that user>) and
-- pinned (only pinned ones). Which channels it looks in is v3's, unchanged (visible_server_channels, taken-down servers,
-- voice chat, search flag, channel_history_ok, my DMs and groups). The client falls back to v3 while this isn't applied.
--
-- The query is built from fixed pieces (user values only go in through USING), so each mix of filters gets its own
-- plan and the index that drives it, instead of one generic plan full of "x is null or ..." that can't use any:
--   * words, no mention: the word index (messages_search_idx), like v3;
--   * a mention: messages_mention_keys_idx, keyed by person and by channel:person. In a server or one chat, one
--     probe per channel ("channel:person"), so only that person's mentions in my channels are read, not all of
--     theirs on the site; everywhere, by person;
--   * words or a mention with no server or chat picked: the newest 5000 hits anywhere, then my channels (v3's shape);
--   * neither (needs a server or one chat): per channel the newest 50 through the index that fits (pinned:
--     messages_pinned_idx; from: messages_channel_author_idx, index-only like v3; has: the partial indexes;
--     has:poll walks polls_channel_created_idx), then the newest 50 of those.
--
-- Indexes on messages, built by hand BEFORE this (concurrently, so writes on messages aren't blocked), in quiet hours.
-- mention_keys must exist first: run its create function and grant below, then the indexes, then this file.
--   create index concurrently if not exists messages_mention_keys_idx on public.messages using gin (public.mention_keys(channel_id, content)) with (fastupdate = off) where strpos(content, '<@') > 0;
--   create index concurrently if not exists messages_embeds_idx on public.messages (channel_id, created_at desc) where embeds is not null;
-- Still from 409: messages_attach_idx, messages_link_idx. polls is small: its index is made here.
-- Re-runnable.

set lock_timeout = '5s';

-- What a message @mentions (<@uuid>; role pings <@&id> aren't people), as index keys: 'uuid' and 'channel:uuid'.
-- Immutable, so it can be indexed (changing its body later won't rebuild the index: use a new name and index). Executable by everyone: an index expression is checked on every insert and
-- update of messages, so a revoke would break writes by any other role (service_role, restores). It reveals nothing.
create or replace function public.mention_keys(cid uuid, content text)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(array_agg(k), '{}'::text[])
  from (
    select distinct x[1] as u
    from regexp_matches(coalesce(content, ''), '<@([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>', 'g') as x
  ) m
  cross join lateral (values (m.u), (cid::text || ':' || m.u)) as v(k);
$$;
grant execute on function public.mention_keys(uuid, text) to public;

-- 409's search_has plus embed (bot cards) and sound (audio files, voice messages included). Polls are rows in polls.
create or replace function public.search_has_v2(content text, path text, embeds jsonb, kind text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case kind
    when 'link' then coalesce(content, '') ~* 'https?://'
    when 'image' then coalesce(path, '') ~* '\.(png|jpe?g|gif|webp|avif)(\?|$)'
    when 'video' then coalesce(path, '') ~* '\.(mp4|webm|mov|m4v)(\?|$)'
    when 'sound' then coalesce(path, '') ~* '\.(mp3|wav|ogg|oga|opus|m4a|weba|flac|aac)(\?|$)'
    when 'file' then path is not null
    when 'embed' then jsonb_typeof(embeds) = 'array' and jsonb_array_length(embeds) > 0
    else true
  end;
$$;
revoke execute on function public.search_has_v2(text, text, jsonb, text) from public, anon;
grant execute on function public.search_has_v2(text, text, jsonb, text) to authenticated;

create index if not exists polls_channel_created_idx on public.polls (channel_id, created_at desc);

create or replace function public.search_messages_v4(q text, sid uuid default null, cid uuid default null, author uuid default null,
  before timestamptz default null, since timestamptz default null, has text default null, mention uuid default null, pinned boolean default false)
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
  pin_only boolean := coalesce(pinned, false);
  scoped boolean := sid is not null or cid is not null;
  me_on boolean;
  chans uuid[];
  conds text;
begin
  if auth.uid() is null or public.is_site_banned(auth.uid())
     or (qq is null and author is null and kind is null and mention is null and not pin_only) then
    return;
  end if;
  if kind is not null and kind not in ('link', 'image', 'video', 'file', 'sound', 'embed', 'poll') then
    return;
  end if;
  -- Without words or a mention there's no index to find hits anywhere: it needs a server or one chat, like v3.
  if qq is null and mention is null and not scoped then
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

  -- from: alone: v3's index-only walk of messages_channel_author_idx, then the rows.
  if qq is null and mention is null and kind is null and not pin_only then
    return query
      with top as (
        select t.channel_id, t.created_at
        from unnest(chans) as ch(id)
        cross join lateral (
          select m1.channel_id, m1.created_at from public.messages m1
          where m1.channel_id = ch.id and m1.author_id = author and m1.created_at < upto and m1.created_at > after_at
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
    return;
  end if;

  -- $1 chans, $2 upto, $3 after_at, $4 author, $5 mention, $6 qq, $7 kind. Only fixed text is added here.
  conds := 'm1.created_at < $2 and m1.created_at > $3';
  if author is not null then
    conds := conds || ' and m1.author_id = $4';
  end if;
  if mention is not null then
    -- Written exactly like messages_mention_keys_idx (and its where), so the planner can use it. In a channel walk the
    -- key is channel:person (ch.id), everywhere it's the person.
    conds := conds || case when scoped
      then ' and strpos(m1.content, ''<@'') > 0 and public.mention_keys(m1.channel_id, m1.content) @> array[ch.id::text || '':'' || $5::text]'
      else ' and strpos(m1.content, ''<@'') > 0 and public.mention_keys(m1.channel_id, m1.content) @> array[$5::text]' end;
  end if;
  if pin_only then
    conds := conds || ' and m1.pinned_at is not null';
  end if;
  if kind = 'link' then
    conds := conds || ' and strpos(m1.content, ''http'') > 0 and public.search_has_v2(m1.content, m1.attachment_path, m1.embeds, $7)';
  elsif kind in ('image', 'video', 'file', 'sound') then
    conds := conds || ' and m1.attachment_path is not null and public.search_has_v2(m1.content, m1.attachment_path, m1.embeds, $7)';
  elsif kind = 'embed' then
    conds := conds || ' and m1.embeds is not null and public.search_has_v2(m1.content, m1.attachment_path, m1.embeds, $7)';
  elsif kind = 'poll' and (qq is not null or mention is not null) then
    conds := conds || ' and exists (select 1 from public.polls pp where pp.message_id = m1.id)';
  end if;
  if qq is not null then
    conds := conds || ' and to_tsvector(''simple'', coalesce(m1.content, '''')) @@ websearch_to_tsquery(''simple'', $6)';
  end if;

  if not scoped then
    -- Everywhere I can read (words or a mention): the newest 5000 hits, then mine (v3's shape).
    return query execute
      'with hits as materialized (
         select m1.id, m1.channel_id, m1.created_at from public.messages m1 where ' || conds || '
         order by m1.created_at desc limit 5000
       )
       select m.* from hits h join public.messages m on m.id = h.id
       where h.channel_id = any($1)
       order by h.created_at desc limit 50'
      using chans, upto, after_at, author, mention, qq, kind;
    return;
  end if;

  if qq is not null and mention is null then
    -- Words in a server or one chat: the word index, narrowed to my channels there (v3).
    return query execute
      'with hits as materialized (
         select m1.id, m1.created_at from public.messages m1 where m1.channel_id = any($1) and ' || conds || '
         order by m1.created_at desc limit 50
       )
       select m.* from hits h join public.messages m on m.id = h.id
       order by h.created_at desc limit 50'
      using chans, upto, after_at, author, mention, qq, kind;
    return;
  end if;

  if kind = 'poll' and mention is null then
    -- Polls are few: walk them by channel, newest first (polls_channel_created_idx), not the channel's messages.
    return query execute
      'with top as (
         select t.id, t.created_at from unnest($1) as ch(id)
         cross join lateral (
           select m1.id, p.created_at from public.polls p join public.messages m1 on m1.id = p.message_id
           where p.channel_id = ch.id and p.created_at < $2 and p.created_at > $3 and m1.channel_id = ch.id and ' || conds || '
           order by p.created_at desc limit 50
         ) t
         order by t.created_at desc limit 50
       )
       select m.* from top t join public.messages m on m.id = t.id
       order by m.created_at desc limit 50'
      using chans, upto, after_at, author, mention, qq, kind;
    return;
  end if;

  -- The rest in a server or one chat (a mention, pinned, has:): the newest 50 per channel through the index that
  -- fits, then the newest 50 of those.
  return query execute
    'with top as (
       select t.id, t.created_at from unnest($1) as ch(id)
       cross join lateral (
         select m1.id, m1.created_at from public.messages m1
         where m1.channel_id = ch.id and ' || conds || '
         order by m1.created_at desc limit 50
       ) t
       order by t.created_at desc limit 50
     )
     select m.* from top t join public.messages m on m.id = t.id
     order by m.created_at desc limit 50'
    using chans, upto, after_at, author, mention, qq, kind;
end;
$$;

revoke execute on function public.search_messages_v4(text, uuid, uuid, uuid, timestamptz, timestamptz, text, uuid, boolean) from public, anon;
grant execute on function public.search_messages_v4(text, uuid, uuid, uuid, timestamptz, timestamptz, text, uuid, boolean) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('search_filters', 'Search filters', 'Discord-style search filters: mentions:, from:, in:, has:, before: / after: / during:, pinned:true, with a people picker and removable chips', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
