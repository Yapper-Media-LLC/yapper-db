-- 411: Yapper HQ link allowlist (094, 142) knows the new domain. Invite links are yapin.gg/invite/... since the
-- Oct 22 rename, and the trigger only allowed yapper.website, so "promote your server" posts were refused.
-- Same function, yapin.gg added, wording says Yapin’ HQ. Re-runnable.
create or replace function public.hq_link_allowlist()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; m text[]; host text; allowed text[] := array[
  'yapin.gg','yapper.website','youtube.com','youtu.be','twitch.tv','tiktok.com','instagram.com','x.com','twitter.com','reddit.com',
  'spotify.com','soundcloud.com','github.com','wikipedia.org','google.com','roblox.com','steampowered.com','steamcommunity.com',
  'tenor.com','giphy.com','imgur.com','pinterest.com','facebook.com','netflix.com','minecraft.net','kick.com','vercel.app','discord.com'];
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  if new.content !~* '(https?://|www\.)' then return new; end if;
  select c.server_id into sid from public.channels c where c.id = new.channel_id;
  if sid is null or sid <> (select default_server_id from public.app_settings limit 1) then return new; end if;
  if public.is_staff() or public.channel_allows(new.channel_id, 'manage_messages') then return new; end if;
  for m in select regexp_matches(new.content, '(?:https?://|www\.)([a-z0-9.-]+)', 'gi') loop
    host := lower(regexp_replace(m[1], '^www\.', ''));
    if not exists (select 1 from unnest(allowed) a where host = a or host like '%.' || a) then
      raise exception 'Only links to well-known sites (YouTube, Twitch, TikTok, Spotify, Reddit and the like) can be posted in Yapin’ HQ.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end; $$;
