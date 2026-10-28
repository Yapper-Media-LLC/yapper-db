-- Verification: the "your name must match your channel" check refused people whose names did match.
--  * A handle typed as "@name" (how TikTok and Instagram show it) became "aname": skeleton() reads "@" as an "a".
--  * Fancy letters (𝐒𝐇𝐘, 𝕽𝖆𝖕𝖍), accents and full-width text were thrown away instead of compared, so a display
--    name written in them matched nothing.
--  * TikTok's share links (vm.tiktok.com / vt.tiktok.com) were refused as "not a tiktok channel".
-- Names are now compared after Unicode compatibility folding (NFKD: 𝐒 → S, ｓ → s, é → e + accent, accent dropped),
-- then the existing look-alike folding. The handle is stored without the leading "@".
-- Review fixes:
--  * Every check of the live apply_verification (changed outside migrations) is kept; compared 2026-10-17.
--  * A handle whose name key is empty (only CJK, Cyrillic, emoji...) gets its own message instead of "must match".
--  * After the match, the handle must be plain text as the site spells it (NFKC, letters/digits/. _ - space).
--  * An application that is 'needs_proof' is still open: no second one next to it.
--  * The rename lock and the impersonation/brand guards use the same folding (patched in place, like 158, since the
--    live versions were edited outside migrations). The rename lock keeps the badge when either the username or
--    the display name still matches. The impersonation and brand guards fold i/l too (name_key over
--    verify_name_key) so they stay at least as strict as before.
--  * Those two guards are SECURITY DEFINER (owner postgres), so their current_user = 'postgres' skip was always
--    true and they never checked anything. They now skip by the request's role setting instead (staff tools, the
--    SQL editor and service_role still skip; signed-in users are checked).
--  * Impersonation guard: an update only checks the name that changed (69 accounts already collide with a verified
--    name; they must still be able to change the other one). New profiles are always checked, whatever the role
--    (sign-up runs as the auth server, bots are made with the service key).
--  * name_of_verified(t): the same check for the bot API (service_role only), and an index so these lookups don't
--    fold every verified name on each sign-up.

create or replace function public.verify_name_key(t text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(
    public.skeleton(regexp_replace(normalize(regexp_replace(coalesce(t, ''), '^\s*@+', ''), NFKD), '[̀-ͯ]', '', 'g')),
    '[^a-z0-9]', '', 'g');
$$;

create or replace function public.apply_verification(p_platform text, p_handle text, p_link text, p_note text, p_proof_path text)
returns uuid language plpgsql security definer set search_path = public as $function$
declare rid uuid; last_rej timestamptz; host text; pathpart text; me_name text; me_display text; handle text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if public.is_site_banned(auth.uid()) then raise exception 'That account is banned'; end if;
  handle := btrim(regexp_replace(btrim(coalesce(p_handle, '')), '^@+', ''));
  if handle = '' then raise exception 'What''s your channel called?'; end if;
  select username, display_name, verified_as into me_name, me_display, pathpart from public.profiles where id = auth.uid();
  if pathpart is not null then raise exception 'You''re already verified'; end if;
  if exists (select 1 from public.verification_requests where user_id = auth.uid() and status in ('pending', 'needs_proof')) then
    raise exception 'You already have an application waiting for review';
  end if;
  select max(reviewed_at) into last_rej from public.verification_requests where user_id = auth.uid() and status = 'rejected';
  if last_rej is not null and last_rej > now() - interval '7 days' then
    raise exception 'You can apply again 7 days after a rejection';
  end if;
  if public.brand_name(handle) or public.brand_name(me_name) then
    if public.brand_name(me_name) then raise exception 'Your username "%" looks like a platform, brand or staff name. Change it to your channel name in Settings → My Profile, then apply again.', me_name; end if; raise exception 'Channel names can''t be platform, brand or staff names';
  end if;
  if public.bad_name(handle) or public.bad_name(coalesce(p_note, '')) then raise exception 'That isn''t allowed'; end if;
  host := lower(regexp_replace(regexp_replace(p_link, '^https?://', '', 'i'), '/.*$', ''));
  host := regexp_replace(host, '^(www|m|mobile)\.', '');
  pathpart := regexp_replace(regexp_replace(p_link, '^https?://[^/]+', '', 'i'), '[?#].*$', '');
  if char_length(btrim(pathpart, '/')) < 2 then raise exception 'Link to your channel page, not the site''s homepage'; end if;
  if (p_platform = 'youtube' and host not in ('youtube.com', 'youtu.be'))
     or (p_platform = 'twitch' and host <> 'twitch.tv')
     or (p_platform = 'tiktok' and host not in ('tiktok.com', 'vm.tiktok.com', 'vt.tiktok.com'))
     or (p_platform = 'instagram' and host <> 'instagram.com')
     or (p_platform = 'x' and host not in ('x.com', 'twitter.com')) then
    raise exception 'That link isn''t a % channel', p_platform;
  end if;
  if public.verify_name_key(handle) = '' then
    raise exception 'We can only verify channel names with Latin letters or numbers for now. Use your @handle from the link instead.';
  end if;
  if exists (select 1 from public.profiles where verified_as is not null
             and public.verify_name_key(split_part(verified_as, ' · ', 2)) = public.verify_name_key(handle)
             ) then
    raise exception 'That channel is already verified on another account';
  end if;
  if public.verify_name_key(handle) not in (public.verify_name_key(me_name), public.verify_name_key(me_display)) then
    raise exception 'Your Yapper username or display name must match your channel name (%). Change it in Settings → My Profile, then apply.', handle;
  end if;
  -- Matched; now the handle itself must be plain (𝐒𝐇𝐘 → SHY is fine, zero-width or look-alike tricks aren't).
  handle := normalize(handle, NFKC);
  if handle !~ '^[A-Za-z0-9._ -]{1,60}$' then
    raise exception 'Use your channel name as it is spelled on the site';
  end if;
  if p_proof_path is null then raise exception 'Add a proof screenshot'; end if;
  if p_proof_path !~ ('^' || auth.uid()::text || '/') then raise exception 'Bad proof'; end if;
  insert into public.verification_requests (user_id, platform, handle, link, note, proof_path)
  values (auth.uid(), p_platform, handle, btrim(p_link), coalesce(p_note, ''), p_proof_path)
  returning id into rid;
  return rid;
end;
$function$;

revoke all on function public.apply_verification(text, text, text, text, text) from public, anon;
grant execute on function public.apply_verification(text, text, text, text, text) to authenticated;

-- Rename lock: changing your name drops the badge unless the username or display name still matches the channel.
do $$
declare
  def text := pg_get_functiondef('public.profile_custom_guard()'::regprocedure);
  old_block text := $b$    handle := lower(regexp_replace(split_part(old.verified_as, ' · ', 2), '[^a-z0-9]', '', 'gi'));
    nm := lower(regexp_replace(coalesce(new.display_name, new.username), '[^a-z0-9]', '', 'gi'));
    if nm <> handle then new.verified_as := null; end if;$b$;
  new_block text := $b$    handle := public.verify_name_key(split_part(old.verified_as, ' · ', 2));
    nm := public.verify_name_key(new.username);
    if handle = '' or handle not in (nm, public.verify_name_key(new.display_name)) then new.verified_as := null; end if;$b$;
  patched text;
begin
  if position('verify_name_key' in def) > 0 then return; end if; -- already patched
  patched := replace(def, old_block, new_block);
  if patched = def then raise exception '171: rename lock block not found in profile_custom_guard, nothing patched'; end if;
  execute patched;
end $$;

-- The verified names, folded once. (Expression index: verify_name_key and name_key are immutable. If either fold
-- ever changes, rebuild it: reindex index public.profiles_verified_name_key_idx.)
create index if not exists profiles_verified_name_key_idx on public.profiles
  (public.name_key(public.verify_name_key(split_part(verified_as, ' · ', 2))))
  where verified_as is not null;

-- Is this name a verified creator's (same folding as the impersonation guard)? For the bot API (service role).
create or replace function public.name_of_verified(t text, not_id uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles v
     where v.verified_as is not null and v.id is distinct from not_id
       and public.name_key(public.verify_name_key(split_part(v.verified_as, ' · ', 2))) = public.name_key(public.verify_name_key(t))
       and length(public.name_key(public.verify_name_key(t))) >= 4);
$$;
revoke all on function public.name_of_verified(text, uuid) from public, anon, authenticated;
grant execute on function public.name_of_verified(text, uuid) to service_role;

-- Impersonation guard: same folding plus i/l; an update checks only the name that changed; inserts always checked.
do $$
declare
  def text := pg_get_functiondef('public.profile_impersonation_guard()'::regprocedure);
  patched text := def;
  pairs text[][] := array[
    [$a$  if current_user in ('postgres', 'service_role') or public.is_site_admin() then return new; end if;$a$,
     $a$  if tg_op = 'UPDATE' and (coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon') or public.is_site_admin()) then return new; end if;$a$],
    [$a$  k_user := public.name_key(new.username);$a$,
     $a$  k_user := case when tg_op = 'INSERT' or new.username is distinct from old.username then public.name_key(public.verify_name_key(new.username)) end;$a$],
    [$a$  k_disp := public.name_key(new.display_name);$a$,
     $a$  k_disp := case when tg_op = 'INSERT' or new.display_name is distinct from old.display_name then public.name_key(public.verify_name_key(new.display_name)) end;$a$],
    [$a$public.name_key(split_part(v.verified_as, ' · ', 2))$a$,
     $a$public.name_key(public.verify_name_key(split_part(v.verified_as, ' · ', 2)))$a$]];
  i int;
begin
  if position('verify_name_key' in def) > 0 then return; end if; -- already patched
  for i in 1 .. array_length(pairs, 1) loop
    if position(pairs[i][1] in patched) = 0 then
      raise exception '171: "%" not found in profile_impersonation_guard, nothing patched', pairs[i][1];
    end if;
    patched := replace(patched, pairs[i][1], pairs[i][2]);
  end loop;
  execute patched;
end $$;

-- Brand guard (verified accounts can't use a brand or country name): same folding, and the role check fixed.
do $$
declare
  def text := pg_get_functiondef('public.verified_name_guard()'::regprocedure);
  patched text := def;
  arg text;
begin
  if position('verify_name_key' in def) > 0 then return; end if; -- already patched
  if position($a$current_user in ('postgres', 'service_role')$a$ in patched) = 0 then
    raise exception '171: role check not found in verified_name_guard, nothing patched';
  end if;
  patched := replace(patched, $a$current_user in ('postgres', 'service_role')$a$,
                     $a$coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')$a$);
  foreach arg in array array['new.username', 'new.display_name', $a$split_part(new.verified_as, ' · ', 2)$a$] loop
    patched := replace(patched, 'public.name_key(' || arg || ')', 'public.name_key(public.verify_name_key(' || arg || '))');
  end loop;
  if patched ~ 'public\.name_key\((?!public\.verify_name_key\()' then
    raise exception '171: a name_key call in verified_name_guard has an argument this patch doesn''t know, nothing patched';
  end if;
  execute patched;
end $$;
