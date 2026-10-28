-- 251: a verified badge only goes away when the username changes (Antic, Oct 18).
-- 045/171 cleared verified_as when the username OR display name changed and neither matched the verified handle, so
-- ~150 verified people matched only by display name lost the badge on any rename (4+ reports). Now a display name
-- change keeps it; changing the username to something that doesn't match the verified channel removes it (unless an
-- admin does it). Taking someone else's verified name is still blocked by profile_impersonation_guard, brand and
-- country names by verified_name_guard. This is the live definition (applied from another session), recorded here.
-- Re-runnable (create or replace).
CREATE OR REPLACE FUNCTION public.profile_custom_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare handle text; nm text;
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and (public.bad_name(new.username) or public.has_adult_link(new.username) or (public.brand_name(new.username) and not public.is_site_admin())) then
    raise exception 'That username isn''t allowed on Yapper. Pick another.';
  end if;
  new.display_name := left(public.clean_name(new.display_name), 32);
  if new.display_name is not null and new.display_name !~ '[[:alnum:]]' then raise exception 'Display names need at least one letter or number'; end if;
  new.pronouns := nullif(left(btrim(coalesce(new.pronouns, '')), 40), '');
  if new.display_name is not null and (public.bad_name(new.display_name) or public.has_adult_link(new.display_name) or (public.brand_name(new.display_name) and not public.is_site_admin())) then
    raise exception 'That display name isn''t allowed';
  end if;
  if new.pronouns is not null and public.bad_name(new.pronouns) then raise exception 'Those pronouns aren''t allowed'; end if;
  if new.accent_color is not null and new.accent_color !~ '^#[0-9a-fA-F]{6}$' then new.accent_color := null; end if;
  if new.accent_color2 is not null and new.accent_color2 !~ '^#[0-9a-fA-F]{6}$' then new.accent_color2 := null; end if;
  -- A verified badge belongs to the account: changing the display name keeps it. Changing the username to something
  -- that doesn't match the verified channel removes it (unless an admin does it).
  if tg_op = 'UPDATE' and old.verified_as is not null and new.verified_as is not distinct from old.verified_as
     and new.username is distinct from old.username
     and not public.is_site_admin() and current_user not in ('postgres', 'service_role') then
    handle := public.verify_name_key(split_part(old.verified_as, ' · ', 2));
    nm := public.verify_name_key(new.username);
    if handle = '' or handle <> nm then new.verified_as := null; end if;
  end if;
  return new;
end;
$function$;
