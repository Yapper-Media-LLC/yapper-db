-- Verification spam filter: brand/platform/org names are refused outright, the link must be a real
-- channel page on the chosen platform, one channel can only be verified once, proof is required.
create or replace function public.brand_name(t text)
returns boolean language sql immutable as $$
  select lower(regexp_replace(coalesce(t, ''), '[^a-z0-9]', '', 'gi')) ~ '^(youtube|yt|facebook|fb|meta|instagram|insta|ig|twitch|tiktok|twitter|x|google|discord|yapper|snapchat|reddit|netflix|spotify|roblox|minecraft|fortnite|epicgames|steam|valve|nintendo|playstation|xbox|microsoft|apple|amazon|tesla|openai|chatgpt|mrbeast|pewdiepie|kaicenat|ishowspeed|xqc|ninja|admin|administrator|moderator|mod|staff|support|official|verified|system|owner|ceo|antic|antic983|nasa|fbi|cia|police|government|gov|un|nato)$'
$$;

create or replace function public.apply_verification(p_platform text, p_handle text, p_link text, p_note text, p_proof_path text)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; last_rej timestamptz; host text; pathpart text; me_name text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if public.is_site_banned(auth.uid()) then raise exception 'That account is banned'; end if;
  select username, verified_as into me_name, pathpart from public.profiles where id = auth.uid();
  if pathpart is not null then raise exception 'You''re already verified'; end if;
  if exists (select 1 from public.verification_requests where user_id = auth.uid() and status = 'pending') then
    raise exception 'You already have an application waiting for review';
  end if;
  select max(reviewed_at) into last_rej from public.verification_requests where user_id = auth.uid() and status = 'rejected';
  if last_rej is not null and last_rej > now() - interval '7 days' then
    raise exception 'You can apply again 7 days after a rejection';
  end if;
  if public.brand_name(p_handle) or public.brand_name(me_name) then
    raise exception 'Verification is for creators'' own channels, not platforms or brands';
  end if;
  if public.bad_name(p_handle) or public.bad_name(coalesce(p_note, '')) then raise exception 'That isn''t allowed'; end if;
  host := lower(regexp_replace(regexp_replace(p_link, '^https?://', '', 'i'), '/.*$', ''));
  host := regexp_replace(host, '^(www|m|mobile)\.', '');
  pathpart := regexp_replace(regexp_replace(p_link, '^https?://[^/]+', '', 'i'), '[?#].*$', '');
  if char_length(btrim(pathpart, '/')) < 2 then raise exception 'Link to your channel page, not the site''s homepage'; end if;
  if (p_platform = 'youtube' and host not in ('youtube.com', 'youtu.be'))
     or (p_platform = 'twitch' and host <> 'twitch.tv')
     or (p_platform = 'tiktok' and host <> 'tiktok.com')
     or (p_platform = 'instagram' and host <> 'instagram.com')
     or (p_platform = 'x' and host not in ('x.com', 'twitter.com')) then
    raise exception 'That link isn''t a % channel', p_platform;
  end if;
  if exists (select 1 from public.profiles where verified_as is not null and lower(split_part(verified_as, ' · ', 2)) = lower(btrim(p_handle))) then
    raise exception 'That channel is already verified on another account';
  end if;
  if p_proof_path is null then raise exception 'Add a proof screenshot'; end if;
  if p_proof_path !~ ('^' || auth.uid()::text || '/') then raise exception 'Bad proof'; end if;
  insert into public.verification_requests (user_id, platform, handle, link, note, proof_path)
  values (auth.uid(), p_platform, btrim(p_handle), btrim(p_link), coalesce(p_note, ''), p_proof_path)
  returning id into rid;
  return rid;
end;
$$;
