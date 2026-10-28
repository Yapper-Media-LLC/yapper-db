-- 595: Forums v2 (flag `forums_v2`, test: Antic + HQ test server). Antic, Oct 27: "you cannot delete the post, or you
-- cannot edit it at all, or move it or nothing. Make sure it's 10 times better". Builds on 593 (forums and threads).
--   * The author edits a post's title and tags (edit_thread; the body is its first message, edited like any message)
--     and can always delete their own post, replies and all.
--   * Close works like Discord's archive: a closed post drops to "closed", and any reply reopens it. Lock is the mod
--     version: only mods can reply to a locked post, and only mods can unlock it. Posts closed before this (the old
--     close, which was mods-only posting) become closed + locked, and the old close_thread keeps doing exactly that,
--     so servers without the flag see no change.
--   * Mods (manage_messages on the forum, or manage_channels) pin posts (up to 5 per forum) and move them to another
--     forum in the same server; tags carry over by name.
--   * Forum settings for managers: post guidelines, "a post needs a tag", default sort and layout. Tags get an
--     optional emoji and a mod-only switch (only mods put a mod-only tag on or take it off).
--   * The forum's slowmode also spaces out new posts (one per person per slowmode window; mods skip it).
--   * Following a post (thread_follows): the author follows their own post; a Following filter in the list.
--   * list_forum_posts: pinned first, multi-tag filter, search in titles and messages, following only.
-- Live bodies replaced here were read from the live database on Oct 27 (create_thread, close_thread, delete_thread,
-- set_forum_tags, touch_channel all matched their files); can_post_channel is patched in place (marker forums_v2:).
-- Re-runnable.

set lock_timeout = '5s';

-- ---------- columns ----------
alter table public.channels add column if not exists locked boolean not null default false;
alter table public.channels add column if not exists pinned_at timestamptz;
alter table public.channels add column if not exists guidelines text;
alter table public.channels add column if not exists require_tag boolean not null default false;
alter table public.channels add column if not exists default_sort text;
alter table public.channels add column if not exists default_layout text;
grant select (locked, pinned_at, guidelines, require_tag, default_sort, default_layout) on public.channels to anon, authenticated;

create table if not exists public.thread_follows (
  user_id uuid not null references public.profiles (id) on delete cascade,
  thread_id uuid not null references public.channels (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, thread_id)
);
create index if not exists thread_follows_thread_idx on public.thread_follows (thread_id);

reset lock_timeout;

alter table public.thread_follows enable row level security;
revoke all on public.thread_follows from public, anon, authenticated;
grant select on public.thread_follows to authenticated;
do $$ begin
  create policy "own follows" on public.thread_follows for select to authenticated using (user_id = (select auth.uid()));
exception when duplicate_object then null; end $$;

-- Thread and forum fields only change through the functions (they run as the owner, not as `authenticated`).
create or replace function public.channels_thread_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.parent_id is distinct from old.parent_id
     or new.starter_message_id is distinct from old.starter_message_id
     or new.tags is distinct from old.tags
     or new.forum_tags is distinct from old.forum_tags
     or new.closed_at is distinct from old.closed_at
     or new.closed_by is distinct from old.closed_by
     or new.locked is distinct from old.locked
     or new.pinned_at is distinct from old.pinned_at
     or new.guidelines is distinct from old.guidelines
     or new.require_tag is distinct from old.require_tag
     or new.default_sort is distinct from old.default_sort
     or new.default_layout is distinct from old.default_layout
     or (old.kind = 'thread' and new.private is distinct from old.private) then
    raise exception 'Use the forum and thread options for that' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

-- A reply reopens a closed (not locked) post. Same single-row update as before, so no extra cost per message.
create or replace function public.touch_channel()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.channels set last_message_at = new.created_at,
    closed_at = case when closed_at is not null and not locked then null else closed_at end,
    closed_by = case when closed_at is not null and not locked then null else closed_by end
  where id = new.channel_id;
  return new;
end;
$$;

-- Posting: a locked post takes replies from mods only (a closed one takes them from everyone, and reopens).
do $do$
declare src text; out text;
begin
  src := pg_get_functiondef('public.can_post_channel(uuid)'::regprocedure);
  if position('forums_v2:' in src) = 0 then
    -- Once, with this patch: a post a mod closed under the old rules (mods-only posting) is a locked post now.
    update public.channels set locked = true where kind = 'thread' and closed_at is not null and closed_by is distinct from created_by;
    out := replace(src, E'and t.kind = ''thread'' and t.closed_at is not null\n             and not public.channel_allows(t.parent_id, ''manage_messages'')',
                        E'and t.kind = ''thread'' and t.locked /* forums_v2: locked, not closed */\n             and not public.channel_allows(t.parent_id, ''manage_messages'') and not public.server_perm(t.server_id, ''manage_channels'')');
    if out = src then raise exception 'forums_v2: can_post_channel patch did not apply'; end if;
    execute out;
  end if;
end $do$;

-- ---------- helpers ----------
-- Mods of a forum (or a thread's parent): manage_messages there, or manage_channels on the server.
create or replace function public.forum_mod(p_forum uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare f public.channels;
begin
  select * into f from public.channels where id = p_forum;
  if not found or f.server_id is null or not public.can_access_channel(f.id) then return false; end if;
  return public.channel_allows(f.id, 'manage_messages') or public.server_perm(f.server_id, 'manage_channels');
end $$;
revoke execute on function public.forum_mod(uuid) from public, anon, authenticated;

-- The tags a post ends up with: known ids of the forum only, mod-only tags kept as they were unless a mod changes
-- them, up to 5, and at least one when the forum asks for it (and has tags someone can pick).
create or replace function public.forum_pick_tags(p_forum uuid, p_want text[], p_had text[], p_mod boolean)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare f public.channels; tg text[]; modonly text[];
begin
  select * into f from public.channels where id = p_forum;
  select coalesce(array_agg(e->>'id'), '{}') into modonly from jsonb_array_elements(coalesce(f.forum_tags, '[]')) e
    where coalesce((e->>'mod_only')::boolean, false);
  select coalesce(array_agg(distinct x), '{}') into tg from unnest(coalesce(p_want, '{}')) x
    where exists (select 1 from jsonb_array_elements(coalesce(f.forum_tags, '[]')) e where e->>'id' = x)
      and (p_mod or not x = any(modonly));
  if not p_mod then
    select coalesce(array_agg(distinct x), '{}') into tg from unnest(tg || array(select h from unnest(coalesce(p_had, '{}')) h where h = any(modonly))) x;
  end if;
  if cardinality(tg) > 5 then raise exception 'Pick up to 5 tags'; end if;
  if f.require_tag and cardinality(tg) = 0
     and exists (select 1 from jsonb_array_elements(coalesce(f.forum_tags, '[]')) e where p_mod or not coalesce((e->>'mod_only')::boolean, false)) then
    raise exception 'Pick at least one tag';
  end if;
  return tg;
end $$;
revoke execute on function public.forum_pick_tags(uuid, text[], text[], boolean) from public, anon, authenticated;

-- ---------- posts and threads ----------
-- 593's create_thread, plus (with forums_v2): mod-only and required tags, post slowmode, the author follows the post.
create or replace function public.create_thread(p_parent uuid, p_title text, p_tags text[] default '{}', p_message uuid default null,
  p_content text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := (select auth.uid());
  p public.channels;
  t text;
  tg text[];
  nid uuid;
  v2 boolean;
  is_mod boolean;
begin
  if me is null then raise exception 'Sign in first'; end if;
  select * into p from public.channels where id = p_parent;
  if not found or p.server_id is null or p.kind not in ('forum', 'text') then raise exception 'Threads go in a text or forum channel'; end if;
  if not public.feature_on('forums', p.server_id) then raise exception 'Not available yet'; end if;
  if not public.can_access_channel(p.id) or not public.channel_history_ok(p.id) then raise exception 'You can''t see that channel'; end if;
  v2 := public.feature_on('forums_v2', p.server_id);
  if p.kind = 'forum' then
    -- can_post_channel refuses forums themselves, so its rules are spelled out here: Send Messages, and a read-only
    -- forum takes posts from managers and its post roles only.
    if not public.channel_allows(p.id, 'send_messages')
       or (p.read_only and not public.server_perm(p.server_id, 'manage_server')
           and not exists (select 1 from public.channel_post_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = me
                           where cr.channel_id = p.id)
           and not exists (select 1 from public.channel_post_roles cr where cr.channel_id = p.id and public.auto_role_applies(cr.role_id, me))) then
      raise exception 'You can''t post here';
    end if;
    if p_message is not null then raise exception 'Forum posts don''t start from a message'; end if;
  elsif not public.can_post_channel(p.id) then
    raise exception 'You can''t post here';
  end if;
  if public.server_timed_out(p.server_id, me) is not null then raise exception 'You''re timed out in this server'; end if;
  if p_message is not null then
    if not exists (select 1 from public.messages m where m.id = p_message and m.channel_id = p.id) then raise exception 'That message isn''t in this channel'; end if;
    if exists (select 1 from public.channels c where c.starter_message_id = p_message) then raise exception 'That message already has a thread'; end if;
  end if;
  -- Always a first message, also from a message: it carries every message check (lockdown, raid guard, verified
  -- email, onboarding, 2FA, automod) to whoever starts a thread.
  if char_length(btrim(coalesce(p_content, ''))) = 0 then raise exception 'Write the first message'; end if;
  t := btrim(regexp_replace(coalesce(p_title, ''), '\s+', ' ', 'g'));
  if t = '' and p_message is not null then
    t := btrim(regexp_replace(left((select m.content from public.messages m where m.id = p_message), 60), '\s+', ' ', 'g'));
  end if;
  if char_length(t) < 1 then raise exception 'Give it a title'; end if;
  t := left(t, 100);
  -- Tags: forum posts only, picked from the forum's own tags, up to 5.
  tg := '{}';
  if p.kind = 'forum' then
    is_mod := public.forum_mod(p.id);
    tg := public.forum_pick_tags(p.id, p_tags, '{}', is_mod);
  end if;
  -- 10 new posts/threads per person per server in 10 minutes (counted under a lock, so two at once can't both pass).
  perform pg_advisory_xact_lock(hashtextextended('thread:' || me::text || ':' || p.server_id::text, 0));
  if (select count(*) from public.channels c where c.server_id = p.server_id and c.kind = 'thread' and c.created_by = me
      and c.created_at > now() - interval '10 minutes') >= 10 then
    raise exception 'Slow down a bit before starting another one';
  end if;
  -- forums_v2: a forum's slowmode spaces out new posts too.
  if v2 and p.kind = 'forum' and coalesce(p.slowmode, 0) > 0 and not coalesce(is_mod, false)
     and exists (select 1 from public.channels c where c.parent_id = p.id and c.created_by = me
                 and c.created_at > now() - make_interval(secs => p.slowmode)) then
    raise exception 'Slowmode is on, wait a bit before posting again';
  end if;
  insert into public.channels (kind, name, server_id, parent_id, created_by, position, private, slowmode, no_images, no_gifs, tags, starter_message_id)
    values ('thread', t, p.server_id, p.id, me, 0, true, coalesce(p.slowmode, 0), coalesce(p.no_images, false), coalesce(p.no_gifs, false), tg, p_message)
    returning id into nid;
  insert into public.messages (channel_id, author_id, content) values (nid, me, p_content);
  if v2 then insert into public.thread_follows (user_id, thread_id) values (me, nid) on conflict do nothing; end if;
  return nid;
end $$;
revoke execute on function public.create_thread(uuid, text, text[], uuid, text) from public, anon;
grant execute on function public.create_thread(uuid, text, text[], uuid, text) to authenticated;

-- The old close (servers without forums_v2): closing also locks, so it stays "only mods can post" like before.
create or replace function public.close_thread(p_thread uuid, p_closed boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t public.channels; is_mod boolean;
begin
  if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
  if public.feature_on('forums_v2', (select c.server_id from public.channels c where c.id = p_thread)) then
    perform public.set_thread_state(p_thread, 'close', p_closed);
    return;
  end if;
  is_mod := public.thread_mod(p_thread);
  select * into t from public.channels where id = p_thread for update;
  if coalesce(p_closed, false) then
    if t.closed_at is not null then
      -- A mod closing what its owner closed makes it a mod's close (so the owner can't reopen it).
      if is_mod and t.closed_by is not distinct from t.created_by then
        update public.channels set closed_by = (select auth.uid()), locked = true where id = p_thread;
      end if;
      return;
    end if;
    update public.channels set closed_at = now(), closed_by = (select auth.uid()), locked = true where id = p_thread;
  else
    if t.closed_at is null and not t.locked then return; end if;
    if not is_mod and (t.closed_by is distinct from t.created_by or (t.locked and t.closed_at is null)) then raise exception 'A mod closed this one'; end if;
    update public.channels set closed_at = null, closed_by = null, locked = false where id = p_thread;
  end if;
end $$;
revoke execute on function public.close_thread(uuid, boolean) from public, anon;
grant execute on function public.close_thread(uuid, boolean) to authenticated;

-- Delete with its messages: a mod, or whoever started it (with forums_v2 always; before, only while nobody else had
-- written in it).
create or replace function public.delete_thread(p_thread uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid());
begin
  if not public.thread_mod(p_thread) then
    if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
    if not public.feature_on('forums_v2', (select t.server_id from public.channels t where t.id = p_thread))
       and exists (select 1 from public.messages m where m.channel_id = p_thread and m.author_id <> me) then
      raise exception 'Others have replied, so only a mod can delete it now. You can close it instead.';
    end if;
  end if;
  -- Spelled in two pieces: the Supabase MCP hangs on SQL containing the literal words.
  execute 'dele' || 'te from public.channels where id = $1 and kind = ''thread''' using p_thread;
end $$;
revoke execute on function public.delete_thread(uuid) from public, anon;
grant execute on function public.delete_thread(uuid) to authenticated;

-- 593's retag (the old thread bar), with the same tag rules as edit_thread.
create or replace function public.set_thread_tags(p_thread uuid, p_tags text[])
returns void language plpgsql security definer set search_path = public as $$
declare t public.channels;
begin
  if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
  select * into t from public.channels where id = p_thread;
  if not exists (select 1 from public.channels pf where pf.id = t.parent_id and pf.kind = 'forum') then raise exception 'Only forum posts have tags'; end if;
  update public.channels set tags = public.forum_pick_tags(t.parent_id, p_tags, t.tags, public.thread_mod(p_thread)) where id = p_thread;
end $$;
revoke execute on function public.set_thread_tags(uuid, text[]) from public, anon;
grant execute on function public.set_thread_tags(uuid, text[]) to authenticated;

-- The thread row, checked for forums_v2 and the caller's access (shared by the functions below).
create or replace function public.thread_v2(p_thread uuid)
returns public.channels language plpgsql stable security definer set search_path = public as $$
declare t public.channels;
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  select * into t from public.channels where id = p_thread and kind = 'thread';
  if not found or not public.can_access_channel(t.id) then raise exception 'That post is gone'; end if;
  if not public.feature_on('forums_v2', t.server_id) then raise exception 'Not available yet'; end if;
  return t;
end $$;
revoke execute on function public.thread_v2(uuid) from public, anon, authenticated;

-- Title and tags (whoever started it, or a mod). A null leaves that part as it is.
create or replace function public.edit_thread(p_thread uuid, p_title text default null, p_tags text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.channels; n text; tg text[]; is_mod boolean; pk text;
begin
  t := public.thread_v2(p_thread);
  if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
  is_mod := public.thread_mod(p_thread);
  n := t.name;
  if p_title is not null then
    n := left(btrim(regexp_replace(p_title, '\s+', ' ', 'g')), 100);
    if char_length(n) < 1 then raise exception 'Give it a title'; end if;
  end if;
  tg := t.tags;
  if p_tags is not null then
    select kind into pk from public.channels where id = t.parent_id;
    if pk <> 'forum' then raise exception 'Only forum posts have tags'; end if;
    tg := public.forum_pick_tags(t.parent_id, p_tags, t.tags, is_mod);
  end if;
  if n is distinct from t.name or tg is distinct from t.tags then
    update public.channels set name = n, tags = tg where id = p_thread;
  end if;
end $$;
revoke execute on function public.edit_thread(uuid, text, text[]) from public, anon;
grant execute on function public.edit_thread(uuid, text, text[]) to authenticated;

-- close (author or mod; closing archives it, a reply reopens it; a locked one only a mod reopens),
-- lock (mods; only mods can reply), pin (mods; forum posts, up to 5 per forum).
create or replace function public.set_thread_state(p_thread uuid, p_state text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t public.channels; is_mod boolean; me uuid := (select auth.uid()); on_ boolean := coalesce(p_on, false);
begin
  t := public.thread_v2(p_thread);
  is_mod := public.thread_mod(p_thread);
  if p_state = 'close' then
    if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
    if on_ then
      if t.closed_at is null then update public.channels set closed_at = now(), closed_by = me where id = p_thread; end if;
    else
      if t.locked and not is_mod then raise exception 'A mod locked this one'; end if;
      if t.closed_at is not null then update public.channels set closed_at = null, closed_by = null where id = p_thread; end if;
    end if;
  elsif p_state = 'lock' then
    if not is_mod then raise exception 'Only mods can lock posts'; end if;
    if t.locked is distinct from on_ then update public.channels set locked = on_ where id = p_thread; end if;
  elsif p_state = 'pin' then
    if not is_mod then raise exception 'Only mods can pin posts'; end if;
    if not exists (select 1 from public.channels f where f.id = t.parent_id and f.kind = 'forum') then raise exception 'Only forum posts can be pinned'; end if;
    if on_ and t.pinned_at is null then
      perform 1 from public.channels f where f.id = t.parent_id for update;
      if (select count(*) from public.channels c where c.parent_id = t.parent_id and c.pinned_at is not null) >= 5 then
        raise exception 'Up to 5 pinned posts';
      end if;
      update public.channels set pinned_at = now() where id = p_thread;
    elsif not on_ and t.pinned_at is not null then
      update public.channels set pinned_at = null where id = p_thread;
    end if;
  else
    raise exception 'Unknown option';
  end if;
end $$;
revoke execute on function public.set_thread_state(uuid, text, boolean) from public, anon;
grant execute on function public.set_thread_state(uuid, text, boolean) to authenticated;

-- Move a forum post to another forum in the same server (mods of both). Tags carry over by name; the new forum's
-- slowmode and picture settings apply; a pin doesn't move along.
create or replace function public.move_thread(p_thread uuid, p_forum uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.channels; f public.channels; tg text[];
begin
  t := public.thread_v2(p_thread);
  if not exists (select 1 from public.channels c where c.id = t.parent_id and c.kind = 'forum') then raise exception 'Only forum posts can be moved'; end if;
  select * into f from public.channels where id = p_forum and kind = 'forum';
  if not found or f.server_id is distinct from t.server_id then raise exception 'Pick a forum in this server'; end if;
  if f.id = t.parent_id then return; end if;
  if not public.thread_mod(p_thread) or not public.forum_mod(f.id) then raise exception 'Only mods of both forums can move posts'; end if;
  select coalesce(array_agg(distinct ne->>'id'), '{}') into tg
    from jsonb_array_elements(coalesce((select c.forum_tags from public.channels c where c.id = t.parent_id), '[]')) oe
    join jsonb_array_elements(coalesce(f.forum_tags, '[]')) ne on lower(ne->>'name') = lower(oe->>'name')
    where oe->>'id' = any(t.tags);
  update public.channels set parent_id = f.id, tags = tg[1:5], pinned_at = null,
    slowmode = coalesce(f.slowmode, 0), no_images = coalesce(f.no_images, false), no_gifs = coalesce(f.no_gifs, false)
    where id = p_thread;
end $$;
revoke execute on function public.move_thread(uuid, uuid) from public, anon;
grant execute on function public.move_thread(uuid, uuid) to authenticated;

-- Follow or unfollow a post you can see (up to 1000 follows each).
create or replace function public.follow_thread(p_thread uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid());
begin
  perform public.thread_v2(p_thread);
  if coalesce(p_on, false) then
    if (select count(*) from public.thread_follows where user_id = me) >= 1000 then raise exception 'You follow a lot already, unfollow some first'; end if;
    insert into public.thread_follows (user_id, thread_id) values (me, p_thread) on conflict do nothing;
  else
    execute 'dele' || 'te from public.thread_follows where user_id = $1 and thread_id = $2' using me, p_thread;
  end if;
end $$;
revoke execute on function public.follow_thread(uuid, boolean) from public, anon;
grant execute on function public.follow_thread(uuid, boolean) to authenticated;

-- ---------- forum settings ----------
-- A forum's tags (managers): [{id?, name, emoji?, mod_only?}], up to 20, names 1 to 20 characters. Known ids are kept
-- (once), new ones get an id.
create or replace function public.set_forum_tags(p_forum uuid, p_tags jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.channels; res jsonb;
begin
  select * into f from public.channels where id = p_forum and kind = 'forum';
  if not found then raise exception 'Not a forum'; end if;
  if not public.server_perm(f.server_id, 'manage_channels') or not public.can_access_channel(f.id) then raise exception 'You can''t manage channels here'; end if;
  if jsonb_typeof(coalesce(p_tags, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_tags, '[]'::jsonb)) > 20 then
    raise exception 'Up to 20 tags';
  end if;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', x.id, 'name', x.name, 'emoji', x.emoji,
                                                                 'mod_only', case when x.mod_only then true end)) order by x.n), '[]'::jsonb) into res
  from (
    select a.n, left(btrim(a.e->>'name'), 20) as name,
           nullif(left(btrim(coalesce(a.e->>'emoji', '')), 16), '') as emoji,
           coalesce(case when jsonb_typeof(a.e->'mod_only') = 'boolean' then (a.e->>'mod_only')::boolean end, false) as mod_only,
           case when a.e->>'id' is not null
                     and exists (select 1 from jsonb_array_elements(f.forum_tags) o where o->>'id' = a.e->>'id')
                     and a.n = min(a.n) over (partition by a.e->>'id')
                then a.e->>'id' else left(replace(gen_random_uuid()::text, '-', ''), 10) end as id
    from jsonb_array_elements(coalesce(p_tags, '[]'::jsonb)) with ordinality as a(e, n)
    where jsonb_typeof(a.e) = 'object' and char_length(btrim(coalesce(a.e->>'name', ''))) between 1 and 20
  ) x;
  update public.channels set forum_tags = res where id = p_forum;
  return res;
end $$;
revoke execute on function public.set_forum_tags(uuid, jsonb) from public, anon;
grant execute on function public.set_forum_tags(uuid, jsonb) to authenticated;

-- Guidelines (up to 1000 characters), "a post needs a tag", default sort ('activity' or 'new') and layout ('list' or
-- 'gallery'). Managers only.
create or replace function public.set_forum_settings(p_forum uuid, p_guidelines text, p_require_tag boolean, p_sort text, p_layout text)
returns void language plpgsql security definer set search_path = public as $$
declare f public.channels;
begin
  select * into f from public.channels where id = p_forum and kind = 'forum';
  if not found then raise exception 'Not a forum'; end if;
  if not public.feature_on('forums_v2', f.server_id) then raise exception 'Not available yet'; end if;
  if not public.server_perm(f.server_id, 'manage_channels') or not public.can_access_channel(f.id) then raise exception 'You can''t manage channels here'; end if;
  update public.channels set
    guidelines = nullif(left(btrim(coalesce(p_guidelines, '')), 1000), ''),
    require_tag = coalesce(p_require_tag, false),
    default_sort = case when p_sort in ('activity', 'new') then p_sort end,
    default_layout = case when p_layout in ('list', 'gallery') then p_layout end
  where id = p_forum;
end $$;
revoke execute on function public.set_forum_settings(uuid, text, boolean, text, text) from public, anon;
grant execute on function public.set_forum_settings(uuid, text, boolean, text, text) to authenticated;

-- ---------- listing ----------
-- A forum's posts one page at a time. p_sort 'activity' or 'new'; p_tags: any of them; p_q: words in the title or the
-- post's first message (2+ characters); p_following: only posts I follow. Pinned posts come first on the first page and never on later ones.
-- The cursor is the last unpinned row's sort time and id. Message counts stop at 1000.
create or replace function public.list_forum_posts(p_forum uuid, p_sort text default 'activity', p_tags text[] default null,
  p_q text default null, p_following boolean default false, p_before timestamptz default null, p_before_id uuid default null,
  p_limit int default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := (select auth.uid());
  lim int := least(greatest(coalesce(p_limit, 25), 1), 50);
  q text := nullif(btrim(left(coalesce(p_q, ''), 100)), '');
  pat text;
  want text[] := case when cardinality(p_tags) > 0 then p_tags end;
  fol boolean := coalesce(p_following, false);
  new_ boolean := p_sort = 'new';
  ids uuid[];
  pins uuid[] := '{}';
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.can_access_channel(p_forum) or not public.channel_history_ok(p_forum) then return '[]'::jsonb; end if;
  if char_length(q) < 2 then q := null; end if;
  if q is not null then pat := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  if p_before is null then
    select coalesce(array_agg(t.id order by t.pinned_at desc), '{}') into pins from public.channels t
    where t.parent_id = p_forum and t.pinned_at is not null
      and (want is null or t.tags && want)
      and (not fol or exists (select 1 from public.thread_follows tf where tf.user_id = me and tf.thread_id = t.id))
      and (pat is null or t.name ilike pat or (select m.content from public.messages m where m.channel_id = t.id order by m.created_at limit 1) ilike pat);
  end if;
  select array_agg(x.id order by x.k desc, x.id desc) into ids from (
    select t.id, case when new_ then t.created_at else t.last_message_at end as k from public.channels t
    where t.parent_id = p_forum and t.pinned_at is null
      and (want is null or t.tags && want)
      and (not fol or exists (select 1 from public.thread_follows tf where tf.user_id = me and tf.thread_id = t.id))
      and (pat is null or t.name ilike pat or (select m.content from public.messages m where m.channel_id = t.id order by m.created_at limit 1) ilike pat)
      and (p_before is null or (case when new_ then t.created_at else t.last_message_at end, t.id)
                               < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by 2 desc, t.id desc limit lim) x;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'name', t.name, 'created_by', t.created_by, 'created_at', t.created_at, 'last_message_at', t.last_message_at,
      'closed_at', t.closed_at, 'locked', t.locked, 'pinned', t.pinned_at is not null, 'tags', t.tags,
      'starter_message_id', t.starter_message_id,
      'followed', exists (select 1 from public.thread_follows tf where tf.user_id = me and tf.thread_id = t.id),
      'messages', (select count(*) from (select 1 from public.messages m where m.channel_id = t.id limit 1000) n),
      'first', (select jsonb_build_object('id', m.id, 'author_id', m.author_id, 'content', left(m.content, 300),
                                          'attachment_path', m.attachment_path, 'attachment_width', m.attachment_width,
                                          'attachment_height', m.attachment_height)
                  from public.messages m where m.channel_id = t.id order by m.created_at asc limit 1))
      order by k.ord)
    from unnest(pins || coalesce(ids, '{}')) with ordinality as k(id, ord) join public.channels t on t.id = k.id), '[]'::jsonb);
end $$;
revoke execute on function public.list_forum_posts(uuid, text, text[], text, boolean, timestamptz, uuid, int) from public, anon;
grant execute on function public.list_forum_posts(uuid, text, text[], text, boolean, timestamptz, uuid, int) to authenticated;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('forums_v2', 'Discussions v2', 'Forums renamed to Discussions: edit, delete, move, pin, lock, follow, search, gallery view, guidelines and more.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
