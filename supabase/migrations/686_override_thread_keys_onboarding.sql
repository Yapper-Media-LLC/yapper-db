-- 686: two bug reports from Oct 29, both left over from 603 (thread permissions), which is on release but not applied.
--
-- 1. Channel and category permissions: ticking Create Threads, Send Messages in Threads or Manage Threads and saving
--    failed with 'violates check constraint "channel_overrides_known_perms"'. The editor offers the three thread keys,
--    the live CHECK still only knows the 12 keys from 265. Same new list as 603 step 7 (603 skips its own step once
--    this has run, and this skips if 603 ran first).
-- 2. Onboarding: picking a plain role for an answer said "it has mod or admin powers". onboarding_role_ok only knew the
--    everyday keys up to send_voice_messages, so any role with Use Big Text (use_headings, on for ~2800 roles since
--    265) or the two everyday thread keys counted as a mod role. The Onboarding tab (components/Onboarding.tsx,
--    EVERYDAY) already lists them, so the picker offered roles the save then refused. Now the database agrees, and a
--    Manage Threads channel override counts as mod power (as 603 meant). 603's two patches of this function find
--    their markers and skip.
--
-- Doesn't turn on any thread permission check: that's still 603 (create_thread, can_post_channel, thread_mod,
-- forum_mod, basic_perm). Re-runnable.

set local lock_timeout = '3s';

create or replace function public.onboarding_role_ok(sid uuid, rid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.roles r
    where r.id = rid and r.server_id = sid and coalesce(r.auto, 'none') = 'none'
      and not coalesce(r.manage_server, false) and not coalesce(r.manage_messages, false)
      and not exists (select 1 from jsonb_each_text(coalesce(r.perms, '{}'::jsonb)) p(k, v)
        where v <> 'false' and k not in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis',
          'create_invite', 'change_nickname', 'connect', 'speak', 'create_polls', 'read_history', 'send_voice_messages', 'view_channel',
          'use_headings', 'create_threads', 'send_in_threads'))
      and not exists (select 1 from public.channel_overrides co
        where co.role_id = r.id and co.allow && array['manage_messages', 'mention_everyone', 'manage_channels', 'manage_roles', 'manage_threads']::text[])
      and not exists (select 1 from public.server_bots b
        where b.server_id = sid and b.bot = 'tickets' and strpos(coalesce(b.config::text, ''), r.id::text) > 0));
$function$;
revoke all on function public.onboarding_role_ok(uuid, uuid) from public, anon, authenticated;

-- Overrides may carry the three thread keys. Last, so the lock on channel_overrides is held only until the commit.
-- Every key the override editor can send (components/ChannelPermissions.tsx, OverridePerm in lib/types.ts).
do $$
declare keys constant text := 'array[''view_channel'', ''send_messages'', ''add_reactions'', ''attach_files'', ''embed_links'', ''mention_everyone'', '
  || '''manage_messages'', ''read_history'', ''connect'', ''speak'', ''send_voice_messages'', ''use_headings'', '
  || '''create_threads'', ''send_in_threads'', ''manage_threads'']::text[]';
begin
  if exists (select 1 from pg_constraint where conname = 'channel_overrides_known_perms'
             and conrelid = 'public.channel_overrides'::regclass
             and pg_get_constraintdef(oid) like '%manage_threads%') then return; end if;
  execute 'alter table public.channel_overrides ' || 'dr' || 'op constraint if exists channel_overrides_known_perms';
  execute 'alter table public.channel_overrides add constraint channel_overrides_known_perms check (allow <@ ' || keys
    || ' and deny <@ ' || keys || ')';
end $$;
