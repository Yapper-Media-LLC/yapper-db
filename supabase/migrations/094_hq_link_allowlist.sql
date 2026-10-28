-- Yapper HQ only: links are allowed to well-known sites only (applied live Oct 15). Staff and managers
-- are excepted; other servers are untouched. Invite links keep their own rule (#promote-your-server).
create or replace function public.hq_link_allowlist()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare sid uuid; m text[]; host text; allowed text[] := array[
  'yapper.website','youtube.com','youtu.be','twitch.tv','tiktok.com','instagram.com','x.com','twitter.com','reddit.com',
  'spotify.com','soundcloud.com','github.com','wikipedia.org','google.com','roblox.com','steampowered.com','steamcommunity.com',
  'tenor.com','giphy.com','imgur.com','pinterest.com','facebook.com','netflix.com','minecraft.net','kick.com','vercel.app','discord.com'];
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  if new.content !~* '(https?://|www\.)' then return new; end if;
  select c.server_id into sid from public.channels c where c.id = new.channel_id;
  if sid is null or sid <> (select default_server_id from public.app_settings limit 1) then return new; end if;
  if public.is_staff() or public.server_perm(sid, 'manage_messages') then return new; end if;
  for m in select regexp_matches(new.content, '(?:https?://|www\.)([a-z0-9.-]+)', 'gi') loop
    host := lower(regexp_replace(m[1], '^www\.', ''));
    if not exists (select 1 from unnest(allowed) a where host = a or host like '%.' || a) then
      raise exception 'Only links to well-known sites (YouTube, Twitch, TikTok, Spotify, Reddit and the like) can be posted in Yapper HQ.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end; $function$;
drop trigger if exists messages_hq_links on public.messages;
create trigger messages_hq_links before insert or update of content on public.messages
  for each row execute function public.hq_link_allowlist();
