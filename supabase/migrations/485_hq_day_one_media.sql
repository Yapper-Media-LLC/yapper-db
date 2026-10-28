-- 485: no pictures or videos from day-one accounts in Yapin' HQ (flag new_account_media, test).
-- Oct 25: alt accounts on throwaway catch-all domains (their script reads the email code) signed up, waited out HQ's
-- 5 minute gate and posted gore in #media 3-5 minutes later. The image check only knows sexual content, so every one
-- scored "ok"; mods banned each about 12 minutes after sign-up. new_account_limits (304) only covers links, DMs and
-- friend requests, not media.
--   * Accounts under 24 hours can't post attachments (voice messages are fine) or media links (same pattern as
--     no_images_channel, 202) in HQ (app_settings.default_server_id). In test mode it also applies on the flag's servers.
--   * Also link previews that show pictures or play video (X/Twitter posts, Reddit threads, TikTok, YouTube, Vimeo).
--   * Edits too: 142's edit guard freezes attachments, but "hi" could be edited into an image link.
--   * Skipped: bots and webhooks (yapper.bot / yapper.webhook), staff, people who can manage messages in the channel.
--   * Own trigger, nothing live is redefined. Cheap first: messages without an attachment or a link return before any
--     lookup; then one PK read (profile), and only for day-one accounts the channel, settings and flag reads.
-- Publish: update feature_flags set mode = 'everyone' where key = 'new_account_media' (data only, no reload).
-- Re-runnable.

set lock_timeout = '5s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('new_account_media', 'Day-one media block in HQ',
  'Accounts under 24 hours can''t post pictures, videos or media links in Yapin'' HQ.',
  'test', array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

create or replace function public.new_account_media_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare born timestamptz; sid uuid; hq uuid; fmode text; fservers uuid[];
begin
  if current_setting('yapper.bot', true) = '1' or current_setting('yapper.webhook', true) = '1' then return new; end if;
  if new.voice_secs is not null then return new; end if;
  if tg_op = 'UPDATE' and new.content is not distinct from old.content then return new; end if;
  if (tg_op = 'UPDATE' or new.attachment_path is null) and position('http' in lower(coalesce(new.content, ''))) = 0 then
    return new;
  end if;
  select created_at into born from public.profiles where id = new.author_id;
  if born is null or born <= now() - interval '24 hours' then return new; end if;

  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then return new; end if;
  select default_server_id into hq from public.app_settings where id;
  select mode, servers into fmode, fservers from public.feature_flags where key = 'new_account_media';
  if not ((fmode = 'everyone' and sid = hq) or (fmode in ('test', 'everyone') and sid = any(fservers))) then
    return new;
  end if;
  if public.is_staff() or public.channel_allows(new.channel_id, 'manage_messages') then return new; end if;

  -- Attachments only on insert: 142 freezes them on edit, and an old one shouldn't block fixing a typo.
  if (tg_op = 'INSERT' and new.attachment_path is not null)
     or new.content ~* 'https?://\S+\.(png|jpe?g|gif|webp|avif|mp4|webm|mov)(?![a-z0-9])'
     or new.content ~* '(tenor\.com|giphy\.com|klipy\.com|imgur\.com|media\.discordapp\.net|cdn\.discordapp\.com)/'
     or new.content ~* '((x|twitter)\.com/[^/\s]+/status/|reddit\.com/r/[^/\s]+/comments/|redd\.it/|tiktok\.com/|vimeo\.com/\d|youtube\.com/(watch|shorts|embed)|youtu\.be/)' then
    raise exception 'New accounts can post pictures and videos here after their first day.' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

revoke all on function public.new_account_media_guard() from public, anon, authenticated;

-- Only when missing: re-making a trigger on messages takes an exclusive lock on every re-run (139 does the same).
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'messages_new_account_media' and tgrelid = 'public.messages'::regclass) then
    create trigger messages_new_account_media before insert or update of content on public.messages
      for each row execute function public.new_account_media_guard();
  end if;
end $$;

reset lock_timeout;
