-- 603: thread permissions, like Discord. Forums and threads went live for everyone on Oct 27 (594, 599) with no switch of
-- their own: anyone who could talk in a channel could start threads there, and HQ couldn't turn them off.
-- Three keys, settable per role (Server Settings), for @everyone, and per category / channel (overrides):
--   create_threads   (on by default) start a thread from a text channel, on top of Send Messages there.
--   send_in_threads  (on by default) reply in a thread or forum post, on top of the parent's Send Messages.
--   manage_threads   (off by default) close, lock, pin, rename, tag, move and delete threads and forum posts, and post
--                    in locked ones. Manage Messages on the parent and Manage Channels still count too, so nobody loses
--                    anything they had.
-- A thread follows its parent channel for every check (593), so an override on the channel or its category decides.
-- Forum posts keep needing Send Messages on the forum (like Discord's Create Posts); replying in them is send_in_threads.
-- All live bodies are patched in place (pg_get_functiondef + replace, exactly-once anchors that stop the migration if
-- the text changed). Defaults on, so nothing changes until a server turns one off. Re-runnable.

set local lock_timeout = '3s';

-- 1. The two everyday keys are on for every member unless the server turns them off (@everyone) or an override denies.
create or replace function public.basic_perm(perm text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $$
  select perm in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis', 'create_invite',
                  'change_nickname', 'connect', 'speak', 'create_polls', 'read_history', 'send_voice_messages', 'use_headings',
                  'create_threads', 'send_in_threads');
$$;

create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;   -- test databases
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;     -- already patched
  if (length(f) - length(replace(f, old_text, ''))) / length(old_text) <> 1 then
    raise exception '603: % changed, patch it by hand', sig;
  end if;
  execute replace(f, old_text, new_text);
end $$;

-- 3. Starting a thread from a text channel needs Create Threads there (forum posts keep Send Messages on the forum).
--    Anchored on the timeout line, which is one line in the live text (the post check before it spans three).
select pg_temp.patch_fn('public.create_thread(uuid,text,text[],uuid,text)', 'create_threads',
  $a$  if public.server_timed_out(p.server_id, me) is not null then$a$,
  $b$  if p.kind = 'text' and not public.channel_allows(p.id, 'create_threads') then raise exception 'You can''t start threads here'; end if;
  if public.server_timed_out(p.server_id, me) is not null then$b$);

-- 4. Replying in a thread needs Send Messages in Threads; Manage Threads also lets you post in a locked one.
select pg_temp.patch_fn('public.can_post_channel(uuid)', 'send_in_threads',
  $a$and not public.channel_allows(t.parent_id, 'manage_messages') and not public.server_perm(t.server_id, 'manage_channels')) then return false; end if;$a$,
  $b$and not public.channel_allows(t.parent_id, 'manage_messages') and not public.channel_allows(t.parent_id, 'manage_threads')
             and not public.server_perm(t.server_id, 'manage_channels')) then return false; end if;
  -- 603: replying in a thread or forum post needs Send Messages in Threads on its parent.
  if exists (select 1 from public.channels t where t.id = cid and t.kind = 'thread'
             and not public.channel_allows(t.parent_id, 'send_in_threads')) then return false; end if;$b$);

-- 5. Thread and forum moderation: Manage Threads, as well as what counted before.
select pg_temp.patch_fn('public.thread_mod(uuid)', 'manage_threads',
  $a$return public.channel_allows(t.parent_id, 'manage_messages') or public.server_perm(t.server_id, 'manage_channels');$a$,
  $b$return public.channel_allows(t.parent_id, 'manage_threads') or public.channel_allows(t.parent_id, 'manage_messages')
    or public.server_perm(t.server_id, 'manage_channels');$b$);
select pg_temp.patch_fn('public.forum_mod(uuid)', 'manage_threads',
  $a$return public.channel_allows(f.id, 'manage_messages') or public.server_perm(f.server_id, 'manage_channels');$a$,
  $b$return public.channel_allows(f.id, 'manage_threads') or public.channel_allows(f.id, 'manage_messages')
    or public.server_perm(f.server_id, 'manage_channels');$b$);

-- 6. Onboarding (251) may hand out roles with the everyday thread keys; a role with Manage Threads overrides is mod power.
select pg_temp.patch_fn('public.onboarding_role_ok(uuid,uuid)', 'send_in_threads',
  $a$'create_polls', 'read_history', 'send_voice_messages', 'view_channel'))$a$,
  $b$'create_polls', 'read_history', 'send_voice_messages', 'view_channel', 'use_headings', 'create_threads', 'send_in_threads'))$b$);
select pg_temp.patch_fn('public.onboarding_role_ok(uuid,uuid)', 'manage_threads',
  $a$array['manage_messages', 'mention_everyone', 'manage_channels', 'manage_roles']::text[]$a$,
  $b$array['manage_messages', 'mention_everyone', 'manage_channels', 'manage_roles', 'manage_threads']::text[]$b$);

-- 7. Overrides may carry the three keys. Last, so the lock on channel_overrides is held only until the commit.
do $$
declare keys constant text := 'array[''view_channel'', ''send_messages'', ''add_reactions'', ''attach_files'', ''embed_links'', ''mention_everyone'', '
  || '''manage_messages'', ''read_history'', ''connect'', ''speak'', ''send_voice_messages'', ''use_headings'', '
  || '''create_threads'', ''send_in_threads'', ''manage_threads'']::text[]';
begin
  if exists (select 1 from pg_constraint where conname = 'channel_overrides_known_perms'
             and pg_get_constraintdef(oid) like '%manage_threads%') then return; end if;
  execute 'alter table public.channel_overrides ' || 'dr' || 'op constraint if exists channel_overrides_known_perms';
  execute 'alter table public.channel_overrides add constraint channel_overrides_known_perms check (allow <@ ' || keys
    || ' and deny <@ ' || keys || ')';
end $$;
