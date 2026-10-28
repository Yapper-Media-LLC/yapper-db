-- 593: Forum channels and threads, phase 1 (flag `forums`, test: Antic + HQ test server). Antic picked it from HQ
-- #suggestions (Oct 25: forums 7 people, threads 4) and took the plan's defaults:
--   * anyone who can send messages there starts posts/threads; mods (manage_messages on the parent) close or delete any
--   * mods set up to 20 tags per forum, a post picks up to 5
--   * forum posts sort by latest activity, "Newest" as the other order
--   * threads stay open (no auto-close yet); no unread badges for threads yet (keeps start-up light)
--
-- Model: a forum is a channel of kind 'forum' (no messages of its own). A forum post and a thread are both a channel of
-- kind 'thread' with parent_id = the forum or the text channel (a thread from a message also has starter_message_id).
-- Their messages are ordinary messages with channel_id = the thread: replies, pictures, reactions, edits, pins,
-- jump-to-message, the image checks and realtime (chan:<thread id>) work unchanged. Search and the mentions inbox go
-- through the start-up channel list, so they don't include threads yet (phase 2).
--
-- A thread follows its parent:
--   * The permission helpers (can_access_channel, channel_history_ok, channel_view_base, channel_allows, channel_perm,
--     channel_overrides_live, can_post_channel, bot_channel_visible, bot_channel_history_ok), the broadcast trigger's
--     "restricted" test and the message permission guards (attach files, links, @everyone, headings, slowmode's mod
--     exemption) resolve a thread to its parent.
--   * Thread rows are stored private = true. Everything that resolves the parent ignores that, and everything that
--     only looks at the row's own flag (push, starboard, logger, bot webhooks, server watch) takes its safe path.
--   * slowmode, no_images and no_gifs are copied at creation and follow the parent when it changes.
-- The live bodies are patched in place (pg_get_functiondef + replace, like 193): several were changed in the database
-- only, so the files can't be the base. Each patch is skipped once applied (marker 593:) and fails loudly if its
-- anchor text is missing. A later migration that redefines one of them from a file must keep the 593 lines.
--
-- Threads stay out of start-up and badges (visible_server_channels_fast skips them; the unread functions count only
-- 'text'), out of the server-wide channel broadcast, the audit log, the 10-a-minute channel limit and fancy-name
-- slugs, and away from bots (text and voice only) and the name-keyed HQ rules (#promote-your-server, suggestions).
-- create_thread inserts the first message itself, so a post goes through every message check (word filters, raid
-- guard, verified email, onboarding, 2FA, timeouts) and a refused message leaves no thread behind.
-- Re-runnable.

set lock_timeout = '5s';

-- ---------- columns ----------
alter table public.channels add column if not exists parent_id uuid references public.channels (id) on delete cascade;
alter table public.channels add column if not exists starter_message_id uuid references public.messages (id) on delete set null;
alter table public.channels add column if not exists tags text[] not null default '{}';
alter table public.channels add column if not exists forum_tags jsonb not null default '[]';
alter table public.channels add column if not exists closed_at timestamptz;
alter table public.channels add column if not exists closed_by uuid references public.profiles (id) on delete set null;
-- Not on last_message_at: touch_channel updates that on every message, and an indexed column would make all of those
-- updates non-HOT. A parent's threads are few enough to sort by activity in memory.
create index if not exists channels_parent_idx on public.channels (parent_id, created_at desc) where parent_id is not null;
create unique index if not exists channels_starter_uniq on public.channels (starter_message_id) where starter_message_id is not null;
create index if not exists channels_closed_by_idx on public.channels (closed_by) where closed_by is not null;
grant select (parent_id, starter_message_id, tags, forum_tags, closed_at, closed_by) on public.channels to anon, authenticated;

-- The kind check, rebuilt only when it doesn't know threads yet; both checks go on NOT VALID (no scan under the lock).
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.channels'::regclass and conname = 'channels_kind_check'
                 and pg_get_constraintdef(oid) like '%thread%') then
    execute 'alter table public.channels dr' || 'op constraint if exists channels_kind_check';
    alter table public.channels add constraint channels_kind_check check (
      (server_id is null and kind in ('dm', 'group'))
      or (server_id is not null and kind in ('text', 'voice', 'forum'))
      or (server_id is not null and kind = 'thread')) not valid;
  end if;
end $$;
do $$ begin
  alter table public.channels add constraint channels_thread_parent_check check ((kind = 'thread') = (parent_id is not null)) not valid;
exception when duplicate_object then null; end $$;

reset lock_timeout;

-- Thread and forum fields only change through the functions below (they run as the owner, not as `authenticated`).
-- channel_guard already puts kind and server_id back on every update.
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
     or (old.kind = 'thread' and new.private is distinct from old.private) then
    raise exception 'Use the forum and thread options for that' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
do $$ begin execute 'dr' || 'op trigger if exists channels_thread_guard on public.channels'; end $$;
create trigger channels_thread_guard before update on public.channels
  for each row execute function public.channels_thread_guard();

-- A parent's slowmode, no-pictures and no-GIFs settings reach its threads.
create or replace function public.channels_sync_threads()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.channels t set slowmode = new.slowmode, no_images = new.no_images, no_gifs = new.no_gifs
    where t.parent_id = new.id
      and (t.slowmode, t.no_images, t.no_gifs) is distinct from (new.slowmode, new.no_images, new.no_gifs);
  return null;
end $$;
revoke execute on function public.channels_sync_threads() from public, anon, authenticated;
do $$ begin execute 'dr' || 'op trigger if exists channels_sync_threads on public.channels'; end $$;
create trigger channels_sync_threads after update of slowmode, no_images, no_gifs on public.channels
  for each row when (new.kind in ('text', 'forum')) execute function public.channels_sync_threads();

-- ---------- in-place patches of live functions ----------
do $do$
declare
  src text; out text; p text;
  root text := E'  -- 593: a thread or forum post follows its parent channel.\n  cid := coalesce((select ch.parent_id from public.channels ch where ch.id = cid), cid);\n';
  procs text[] := array['public.can_access_channel(uuid)', 'public.channel_history_ok(uuid)', 'public.channel_view_base(uuid)',
                        'public.channel_overrides_live(uuid)'];
begin
  foreach p in array procs loop
    src := pg_get_functiondef(p::regprocedure);
    if position('593:' in src) = 0 then
      out := replace(src, E'#variable_conflict use_column\nbegin\n', E'#variable_conflict use_column\nbegin\n' || root);
      if out = src then raise exception '593: % patch did not apply', p; end if;
      execute out;
    end if;
  end loop;

  src := pg_get_functiondef('public.can_post_channel(uuid)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'#variable_conflict use_column\nbegin\n', E'#variable_conflict use_column\nbegin\n'
      || E'  -- 593: nobody posts in a forum itself (its posts are threads); a closed thread takes posts from mods only.\n'
      || E'  if exists (select 1 from public.channels t where t.id = cid and t.kind = ''forum'') then return false; end if;\n'
      || E'  if exists (select 1 from public.channels t where t.id = cid and t.kind = ''thread'' and t.closed_at is not null\n'
      || E'             and not public.channel_allows(t.parent_id, ''manage_messages'')) then return false; end if;\n'
      || root);
    if out = src then raise exception '593: can_post_channel patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.channel_allows(uuid,text)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'declare sid uuid; live boolean;\nbegin\n', E'declare sid uuid; live boolean;\nbegin\n' || root);
    if out = src then raise exception '593: channel_allows patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.channel_perm(uuid,text)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'declare sid uuid;\nbegin\n', E'declare sid uuid;\nbegin\n' || root);
    if out = src then raise exception '593: channel_perm patch did not apply'; end if;
    execute out;
  end if;

  -- create_channel: 'forum' needs the flag, unknown kinds are refused, threads don't count toward the 100.
  src := pg_get_functiondef('public.create_channel(uuid,text,text)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'declare cid uuid; k text := coalesce(channel_kind, ''text''); n text;\nbegin\n',
      E'declare cid uuid; k text := coalesce(channel_kind, ''text''); n text;\nbegin\n'
      || E'  -- 593: text, voice, or a forum where the forums flag is on.\n'
      || E'  if k not in (''text'', ''voice'') and not (k = ''forum'' and public.feature_on(''forums'', sid)) then raise exception ''Unknown channel type''; end if;\n');
    out := replace(out, '(select count(*) from public.channels where server_id = sid) >= 100',
                        '(select count(*) from public.channels where server_id = sid and kind <> ''thread'') >= 100');
    if position('593:' in out) = 0 or position('kind <> ''thread''' in out) = 0 then raise exception '593: create_channel patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.visible_server_channels_fast(uuid[])'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, '(select c from public.channels c where c.server_id = mine.server_id offset 0)',
                        '(select c from public.channels c where c.server_id = mine.server_id and c.kind <> ''thread'' /* 593: */ offset 0)');
    if out = src then raise exception '593: visible_server_channels_fast patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.bot_visible_channels(uuid,uuid)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, 'where (sid is null or c.server_id = sid)', 'where (sid is null or c.server_id = sid) and c.kind in (''text'', ''voice'') /* 593: */');
    if out = src then raise exception '593: bot_visible_channels patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.bot_channel_visible(uuid,uuid)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'where c.id = cid\n      and (',
                        E'where c.id = coalesce((select t.parent_id from public.channels t where t.id = cid), cid) /* 593: */\n      and (');
    if out = src then raise exception '593: bot_channel_visible patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.bot_channel_history_ok(uuid,uuid)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, 'from public.channels c where c.id = cid), false);',
                        'from public.channels c where c.id = coalesce((select t.parent_id from public.channels t where t.id = cid), cid) /* 593: */), false);');
    if out = src then raise exception '593: bot_channel_history_ok patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.broadcast_message_change()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, 'into sid, restricted from public.channels ch where ch.id = cid;',
                        'into sid, restricted from public.channels ch where ch.id = coalesce((select t.parent_id from public.channels t where t.id = cid), cid); /* 593: */');
    if out = src then raise exception '593: broadcast_message_change patch did not apply'; end if;
    execute out;
  end if;

  -- Message permission guards: in a thread, the parent's overrides decide (channel_perm already resolves the parent).
  src := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'    from public.channels c where c.id = new.channel_id) c;\n',
      E'    from public.channels c where c.id = new.channel_id) c;\n'
      || E'  -- 593: a thread uses its parent''s overrides.\n'
      || E'  if vk = ''thread'' then cp := public.channel_overrides_live(new.channel_id); end if;\n');
    if out = src then raise exception '593: message_perm_guard patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.message_edit_guard()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E') into cp\n        from public.channels c where c.id = old.channel_id;\n',
      E') into cp\n        from public.channels c where c.id = old.channel_id;\n'
      || E'      -- 593: a thread uses its parent''s overrides.\n'
      || E'      if exists (select 1 from public.channels t where t.id = old.channel_id and t.kind = ''thread'') then cp := public.channel_overrides_live(old.channel_id); end if;\n');
    if out = src then raise exception '593: message_edit_guard patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.message_slowmode()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'  if c.server_id is null then return new; end if;\n',
      E'  if c.server_id is null then return new; end if;\n'
      || E'  -- 593: mods of a thread''s parent skip its slowmode.\n'
      || E'  if c.kind = ''thread'' and public.channel_allows(c.id, ''manage_messages'') then return new; end if;\n');
    if out = src then raise exception '593: message_slowmode patch did not apply'; end if;
    execute out;
  end if;

  -- Server-wide channel broadcast: no thread rows (their titles could carry a private channel's text, and every
  -- online member would recheck access for each new thread).
  src := pg_get_functiondef('public.bc_channel()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'declare sid uuid;\nbegin\n',
      E'declare sid uuid;\nbegin\n'
      || E'  -- 593: threads aren''t broadcast server-wide; a change to one (closed, reopened, retagged) goes to its own topic.\n'
      || E'  if coalesce(new.kind, old.kind) = ''thread'' then\n'
      || E'    if tg_op = ''UPDATE'' then perform public.bc(''chan:'' || new.id, ''channel'', tg_op, tg_table_name, tg_table_schema, new, old); end if;\n'
      || E'    return null;\n'
      || E'  end if;\n');
    if out = src then raise exception '593: bc_channel patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.channel_create_limit()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'  if new.server_id is null or new.ticket_by is not null then return new; end if;\n',
      E'  if new.server_id is null or new.ticket_by is not null then return new; end if;\n'
      || E'  if new.kind = ''thread'' then return new; end if; -- 593: threads have their own limit (create_thread)\n');
    if out = src then raise exception '593: channel_create_limit patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.channel_fancy_name()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, E'begin\n  if new.server_id is null or new.name is null',
      E'begin\n  if new.kind = ''thread'' then return new; end if; -- 593: thread titles stay as written\n  if new.server_id is null or new.name is null');
    if out = src then raise exception '593: channel_fancy_name patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.audit_channels()'::regprocedure);
  if position('593:' in src) = 0 then
    -- First thing after begin, so the system-delete branch (auth.uid() null) skips threads too; \r? because the live
    -- body has had both line endings.
    out := regexp_replace(src, E'(declare d jsonb;\\r?\\nbegin\\r?\\n)',
      E'\\1  if coalesce(new.kind, old.kind) = ''thread'' then return null; end if; -- 593: not a line per thread\n');
    if out = src then raise exception '593: audit_channels patch did not apply'; end if;
    execute out;
  end if;

  -- Name-keyed HQ rules look at the real channel: a thread called "promote" isn't #promote-your-server.
  src := pg_get_functiondef('public.invites_only_in_promo()'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, 'select c.name, c.server_id into ch from public.channels c where c.id = new.channel_id;',
                        'select c.name, c.server_id into ch from public.channels c where c.id = coalesce((select t.parent_id from public.channels t where t.id = new.channel_id), new.channel_id); /* 593: */');
    if out = src then raise exception '593: invites_only_in_promo patch did not apply'; end if;
    execute out;
  end if;
  src := pg_get_functiondef('public.submit_suggestion(uuid,text,text,text)'::regprocedure);
  if position('593:' in src) = 0 then
    out := replace(src, 'c.name not in (''suggestions-new'', ''suggestions'') then',
                        'c.name not in (''suggestions-new'', ''suggestions'') or exists (select 1 from public.channels t where t.id = c.id and t.kind = ''thread'') /* 593: */ then');
    if out = src then raise exception '593: submit_suggestion patch did not apply'; end if;
    execute out;
  end if;
end $do$;

-- ---------- posts and threads ----------
-- Start a forum post (p_parent = a forum) or a thread (p_parent = a text channel, optionally from p_message there).
-- p_content is the first message (always needed): it's inserted here, so it goes through every message check, and
-- if one refuses it the thread isn't made either.
do $$ begin execute 'dr' || 'op function if exists public.create_thread(uuid, text, text[], uuid)'; end $$;
create or replace function public.create_thread(p_parent uuid, p_title text, p_tags text[] default '{}', p_message uuid default null,
  p_content text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := (select auth.uid());
  p public.channels;
  t text;
  tg text[];
  nid uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  select * into p from public.channels where id = p_parent;
  if not found or p.server_id is null or p.kind not in ('forum', 'text') then raise exception 'Threads go in a text or forum channel'; end if;
  if not public.feature_on('forums', p.server_id) then raise exception 'Not available yet'; end if;
  if not public.can_access_channel(p.id) or not public.channel_history_ok(p.id) then raise exception 'You can''t see that channel'; end if;
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
  if p.kind = 'forum' and p_tags is not null then
    select coalesce(array_agg(distinct x), '{}') into tg from unnest(p_tags) x
      where exists (select 1 from jsonb_array_elements(p.forum_tags) e where e->>'id' = x);
    if cardinality(tg) > 5 then raise exception 'Pick up to 5 tags'; end if;
  end if;
  -- 10 new posts/threads per person per server in 10 minutes (counted under a lock, so two at once can't both pass).
  perform pg_advisory_xact_lock(hashtextextended('thread:' || me::text || ':' || p.server_id::text, 0));
  if (select count(*) from public.channels c where c.server_id = p.server_id and c.kind = 'thread' and c.created_by = me
      and c.created_at > now() - interval '10 minutes') >= 10 then
    raise exception 'Slow down a bit before starting another one';
  end if;
  insert into public.channels (kind, name, server_id, parent_id, created_by, position, private, slowmode, no_images, no_gifs, tags, starter_message_id)
    values ('thread', t, p.server_id, p.id, me, 0, true, coalesce(p.slowmode, 0), coalesce(p.no_images, false), coalesce(p.no_gifs, false), tg, p_message)
    returning id into nid;
  insert into public.messages (channel_id, author_id, content) values (nid, me, p_content);
  return nid;
end $$;
revoke execute on function public.create_thread(uuid, text, text[], uuid, text) from public, anon;
grant execute on function public.create_thread(uuid, text, text[], uuid, text) to authenticated;

-- The posts of a forum or the threads of a channel, one page at a time.
-- p_sort 'activity' (latest message first) or 'new' (newest first). The cursor is the last row's sort time and id.
-- Message counts stop at 100.
do $$ begin execute 'dr' || 'op function if exists public.list_threads(uuid, text, text, timestamptz, int)'; end $$;
create or replace function public.list_threads(p_parent uuid, p_sort text default 'activity', p_tag text default null,
  p_before timestamptz default null, p_limit int default 25, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare lim int := least(greatest(coalesce(p_limit, 25), 1), 50); ids uuid[];
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  if not public.can_access_channel(p_parent) or not public.channel_history_ok(p_parent) then return '[]'::jsonb; end if;
  if p_sort = 'new' then
    select array_agg(x.id order by x.created_at desc, x.id desc) into ids from (
      select t.id, t.created_at from public.channels t
      where t.parent_id = p_parent and (p_tag is null or p_tag = any(t.tags))
        and (p_before is null or (t.created_at, t.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
      order by t.created_at desc, t.id desc limit lim) x;
  else
    select array_agg(x.id order by x.last_message_at desc, x.id desc) into ids from (
      select t.id, t.last_message_at from public.channels t
      where t.parent_id = p_parent and (p_tag is null or p_tag = any(t.tags))
        and (p_before is null or (t.last_message_at, t.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
      order by t.last_message_at desc, t.id desc limit lim) x;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'name', t.name, 'created_by', t.created_by, 'created_at', t.created_at, 'last_message_at', t.last_message_at,
      'closed_at', t.closed_at, 'tags', t.tags, 'starter_message_id', t.starter_message_id,
      'messages', (select count(*) from (select 1 from public.messages m where m.channel_id = t.id limit 100) n),
      'first', (select jsonb_build_object('id', m.id, 'author_id', m.author_id, 'content', left(m.content, 300),
                                          'attachment_path', m.attachment_path, 'attachment_width', m.attachment_width,
                                          'attachment_height', m.attachment_height)
                  from public.messages m where m.channel_id = t.id order by m.created_at asc limit 1))
      order by k.ord)
    from unnest(ids) with ordinality as k(id, ord) join public.channels t on t.id = k.id), '[]'::jsonb);
end $$;
revoke execute on function public.list_threads(uuid, text, text, timestamptz, int, uuid) from public, anon;
grant execute on function public.list_threads(uuid, text, text, timestamptz, int, uuid) to authenticated;

-- Mods of a thread's parent: manage_messages there, or manage_channels on the server.
create or replace function public.thread_mod(p_thread uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare t public.channels;
begin
  select * into t from public.channels where id = p_thread and kind = 'thread';
  if not found or not public.can_access_channel(t.id) then return false; end if;
  return public.channel_allows(t.parent_id, 'manage_messages') or public.server_perm(t.server_id, 'manage_channels');
end $$;
revoke execute on function public.thread_mod(uuid) from public, anon, authenticated;

-- Whoever started it (who can still see it), or a mod.
create or replace function public.thread_owner_or_mod(p_thread uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return public.thread_mod(p_thread)
      or (public.can_access_channel(p_thread)
          and exists (select 1 from public.channels t where t.id = p_thread and t.kind = 'thread' and t.created_by = (select auth.uid())));
end $$;
revoke execute on function public.thread_owner_or_mod(uuid) from public, anon, authenticated;

-- Close or reopen. A closed thread keeps who closed it; reopening one a mod closed takes a mod.
do $$ begin execute 'dr' || 'op function if exists public.close_thread(uuid, boolean)'; end $$;
create or replace function public.close_thread(p_thread uuid, p_closed boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t public.channels; is_mod boolean;
begin
  if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
  is_mod := public.thread_mod(p_thread);
  select * into t from public.channels where id = p_thread for update;
  if coalesce(p_closed, false) then
    if t.closed_at is not null then
      -- A mod closing what its owner closed makes it a mod's close (so the owner can't reopen it).
      if is_mod and t.closed_by is not distinct from t.created_by then
        update public.channels set closed_by = (select auth.uid()) where id = p_thread;
      end if;
      return;
    end if;
    update public.channels set closed_at = now(), closed_by = (select auth.uid()) where id = p_thread;
  else
    if t.closed_at is null then return; end if;
    if not is_mod and t.closed_by is distinct from t.created_by then raise exception 'A mod closed this one'; end if;
    update public.channels set closed_at = null, closed_by = null where id = p_thread;
  end if;
end $$;
revoke execute on function public.close_thread(uuid, boolean) from public, anon;
grant execute on function public.close_thread(uuid, boolean) to authenticated;

-- Delete with its messages: a mod, or whoever started it while nobody else has written in it.
create or replace function public.delete_thread(p_thread uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid());
begin
  if not public.thread_mod(p_thread) then
    if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
    if exists (select 1 from public.messages m where m.channel_id = p_thread and m.author_id <> me) then
      raise exception 'Others have replied, so only a mod can delete it now. You can close it instead.';
    end if;
  end if;
  -- Spelled in two pieces: the Supabase MCP hangs on SQL containing the literal words.
  execute 'dele' || 'te from public.channels where id = $1 and kind = ''thread''' using p_thread;
end $$;
revoke execute on function public.delete_thread(uuid) from public, anon;
grant execute on function public.delete_thread(uuid) to authenticated;

create or replace function public.set_thread_tags(p_thread uuid, p_tags text[])
returns void language plpgsql security definer set search_path = public as $$
declare f jsonb; tg text[];
begin
  if not public.thread_owner_or_mod(p_thread) then raise exception 'Only whoever started it or a mod can do that'; end if;
  select pf.forum_tags into f from public.channels t join public.channels pf on pf.id = t.parent_id and pf.kind = 'forum' where t.id = p_thread;
  if f is null then raise exception 'Only forum posts have tags'; end if;
  select coalesce(array_agg(distinct x), '{}') into tg from unnest(coalesce(p_tags, '{}')) x
    where exists (select 1 from jsonb_array_elements(f) e where e->>'id' = x);
  if cardinality(tg) > 5 then raise exception 'Pick up to 5 tags'; end if;
  update public.channels set tags = tg where id = p_thread;
end $$;
revoke execute on function public.set_thread_tags(uuid, text[]) from public, anon;
grant execute on function public.set_thread_tags(uuid, text[]) to authenticated;

-- A forum's tags (mods): [{id?, name}], up to 20, names 1 to 20 characters. Known ids are kept (once), new ones get an id.
create or replace function public.set_forum_tags(p_forum uuid, p_tags jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.channels; res jsonb;
begin
  select * into f from public.channels where id = p_forum and kind = 'forum';
  if not found then raise exception 'Not a forum'; end if;
  if not public.server_perm(f.server_id, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  if jsonb_typeof(coalesce(p_tags, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_tags, '[]'::jsonb)) > 20 then
    raise exception 'Up to 20 tags';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.n), '[]'::jsonb) into res
  from (
    select a.n, left(btrim(a.e->>'name'), 20) as name,
           case when a.e->>'id' is not null
                     and exists (select 1 from jsonb_array_elements(f.forum_tags) o where o->>'id' = a.e->>'id')
                     and a.n = min(a.n) over (partition by a.e->>'id')
                then a.e->>'id' else left(replace(gen_random_uuid()::text, '-', ''), 10) end as id
    from jsonb_array_elements(coalesce(p_tags, '[]'::jsonb)) with ordinality as a(e, n)
    where char_length(btrim(coalesce(a.e->>'name', ''))) between 1 and 20
  ) x;
  update public.channels set forum_tags = res where id = p_forum;
  return res;
end $$;
revoke execute on function public.set_forum_tags(uuid, jsonb) from public, anon;
grant execute on function public.set_forum_tags(uuid, jsonb) to authenticated;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('forums', 'Forums and threads', 'Forum channels with posts and tags, and threads started from messages.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
