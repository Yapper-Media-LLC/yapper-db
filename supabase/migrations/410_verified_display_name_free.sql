-- 410: changing your display name keeps the verified badge again; only a new username that isn't the verified
-- channel's takes it off (Antic, Oct 22, after a creator verified at 19:41 lost it by changing his display name).
-- Reverses the display name half of 317. The rest of the function is the live text from Oct 22 (pg_get_functiondef).
-- Re-runnable (create or replace).

set lock_timeout = '5s';

create or replace function public.profile_custom_guard()
returns trigger language plpgsql set search_path = public as $$
declare handle text;
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and (public.bad_name(new.username) or public.has_adult_link(new.username) or (public.brand_name(new.username) and not public.is_site_admin())) then
    raise exception 'That username isn''t allowed on Yapper. Pick another.';
  end if;
  new.display_name := left(public.clean_name(new.display_name), 32);
  if new.display_name is not null and new.display_name !~ '[[:alnum:]]' then raise exception 'Display names need at least one letter or number'; end if;
  new.pronouns := nullif(left(btrim(coalesce(new.pronouns, '')), 40), '');
  if new.display_name is not null and (tg_op = 'INSERT' or new.display_name is distinct from old.display_name)
     and (public.bad_name(new.display_name) or public.has_adult_link(new.display_name) or (public.brand_name(new.display_name) and not public.is_site_admin())) then
    raise exception 'That display name isn''t allowed';
  end if;
  if new.pronouns is not null and public.bad_name(new.pronouns) then raise exception 'Those pronouns aren''t allowed'; end if;
  if new.accent_color is not null and new.accent_color !~ '^#[0-9a-fA-F]{6}$' then new.accent_color := null; end if;
  if new.accent_color2 is not null and new.accent_color2 !~ '^#[0-9a-fA-F]{6}$' then new.accent_color2 := null; end if;
  -- 410: the verified badge is tied to the username only; display names are free.
  if tg_op = 'UPDATE' and old.verified_as is not null and new.verified_as is not distinct from old.verified_as
     and new.username is distinct from old.username
     and not public.is_site_admin() and current_user not in ('postgres', 'service_role') then
    handle := public.verify_name_key(split_part(old.verified_as, ' · ', 2));
    if handle = '' or public.verify_name_key(new.username) <> handle then
      new.verified_as := null;
    end if;
  end if;
  return new;
end;
$$;

reset lock_timeout;
