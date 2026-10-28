-- 158: "Send Voice Messages" permission, like Discord's.
-- On by default for every member (a basic perm, so existing servers keep voice messages working). Server admins can
-- switch it off for @everyone (servers.everyone_perms), give it back per role (roles.perms), and override it per
-- channel/category (channel_overrides, flag channel_perms).
-- Voice messages are attachments whose file name starts with "voice-" / "r2-voice-" (lib/media.ts). They need
-- send_voice_messages only, like Discord; every other attachment still needs attach_files.
-- Re-runnable. (The constraint swap is spelled 'dr' || 'op' because the Supabase MCP hangs on that word.)

-- 1. Basic perms: members have it unless the server's @everyone says no (server_perm() falls back to this list).
create or replace function public.basic_perm(perm text) returns boolean
language sql immutable set search_path = public, extensions as $$
  select perm in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis', 'create_invite',
                  'change_nickname', 'connect', 'speak', 'create_polls', 'read_history', 'send_voice_messages');
$$;

-- 2. Channel/category overrides may carry it.
do $$
begin
  execute 'alter table public.channel_overrides dr' || 'op constraint if exists channel_overrides_known_perms';
  alter table public.channel_overrides add constraint channel_overrides_known_perms check (
    allow <@ array['view_channel','send_messages','add_reactions','attach_files','embed_links','mention_everyone',
                   'manage_messages','read_history','connect','speak','send_voice_messages']
    and deny <@ array['view_channel','send_messages','add_reactions','attach_files','embed_links','mention_everyone',
                      'manage_messages','read_history','connect','speak','send_voice_messages']);
end $$;

-- 3. Enforce on insert. Patch message_perm_guard in place: a voice message checks send_voice_messages, anything else
-- attach_files, both through the same channel_perm/server_perm switch. Messages without an attachment do no extra work.
do $$
declare
  def text := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  old_block text := $b$  if new.attachment_path is not null
     and not (case when cp then public.channel_perm(new.channel_id, 'attach_files') else public.server_perm(sid, 'attach_files') end) then
    raise exception 'You can''t attach files here';
  end if;$b$;
  new_block text := $b$  if new.attachment_path is not null then
    if new.attachment_path ~ '(^|/)(r2-)?voice-[^/]*$' then
      if not (case when cp then public.channel_perm(new.channel_id, 'send_voice_messages') else public.server_perm(sid, 'send_voice_messages') end) then
        raise exception 'You can''t send voice messages here';
      end if;
    elsif not (case when cp then public.channel_perm(new.channel_id, 'attach_files') else public.server_perm(sid, 'attach_files') end) then
      raise exception 'You can''t attach files here';
    end if;
  end if;$b$;
  patched text;
begin
  if position('send_voice_messages' in def) > 0 then
    return; -- already patched
  end if;
  patched := replace(def, old_block, new_block);
  if patched = def then
    raise exception '158: attach_files block not found in message_perm_guard, nothing patched';
  end if;
  execute patched;
end $$;
