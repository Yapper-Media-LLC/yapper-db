-- 378: verifying a channel whose own name trips the brand filter (Oct 22). "ChromeRing" starts with "chrome", so
-- brand_like() flags it, and a display name built on it ("chromering - /username") was refused as "a brand or
-- country" although the brand part is just the verified channel's own name.
-- verified_name_guard (live text, 171) now also accepts a name that starts with the verified handle when that handle
-- itself is brand- or country-like: the flagged part comes from the channel, not from someone else's brand.
-- A short handle that isn't brand-like ("you", "youtu") gets nothing new: "youtube" is still refused for it. Nor does
-- a channel named exactly like a brand ("google"), and the name must read as the channel name on screen.
-- Re-runnable. Function only (no table locks).
create or replace function public.verified_name_guard()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare handle text; raw text; plain text; own_brand boolean;
begin
  if new.verified_as is null or coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'UPDATE' and new.verified_as is not distinct from old.verified_as
     and new.username is not distinct from old.username and new.display_name is not distinct from old.display_name then return new; end if;
  raw := split_part(new.verified_as, ' · ', 2);
  handle := public.name_key(public.verify_name_key(raw));
  -- Only a channel name longer than a brand ("chromering", not "google"), compared as it reads on screen (letters
  -- and digits, lower case: no NFKD, so tiny or superscript letters can't hide the rest of the channel name).
  plain := lower(regexp_replace(raw, '[^[:alnum:]]', '', 'g'));
  own_brand := length(handle) >= 7 and length(plain) >= 7 and not public.brand_name(raw)
    and (public.brand_like(raw) or public.country_name(raw));
  if (public.brand_like(new.username) or public.country_name(new.username))
       and public.name_key(public.verify_name_key(new.username)) <> handle
       and not (own_brand and starts_with(lower(regexp_replace(new.username, '[^[:alnum:]]', '', 'g')), plain))
     or (new.display_name is not null and (public.brand_like(new.display_name) or public.country_name(new.display_name))
       and public.name_key(public.verify_name_key(new.display_name)) <> handle
       and not (own_brand and starts_with(lower(regexp_replace(new.display_name, '[^[:alnum:]]', '', 'g')), plain))) then
    if tg_op = 'UPDATE' and old.verified_as is null then
      raise exception 'Can''t verify this account: its name is a brand or country, not the verified channel.' using errcode = 'check_violation';
    end if;
    raise exception 'Verified accounts can''t use a brand or country name. Pick another.' using errcode = 'check_violation';
  end if;
  return new;
end $function$;
