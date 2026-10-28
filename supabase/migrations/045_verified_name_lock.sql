-- A verified badge is tied to the name it was approved for: renaming (username or display name)
-- to something that doesn't match the verified channel drops the badge. Also: username renames
-- go through the name filter.
create or replace function public.profile_custom_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare handle text; nm text;
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and (public.bad_name(new.username) or public.has_adult_link(new.username)) then
    raise exception 'That username isn''t allowed on Yapper. Pick another.';
  end if;
  new.display_name := nullif(left(btrim(coalesce(new.display_name, '')), 32), '');
  new.pronouns := nullif(left(btrim(coalesce(new.pronouns, '')), 40), '');
  if new.display_name is not null and (public.bad_name(new.display_name) or public.has_adult_link(new.display_name) or public.brand_name(new.display_name)) then
    raise exception 'That display name isn''t allowed';
  end if;
  if new.pronouns is not null and public.bad_name(new.pronouns) then raise exception 'Those pronouns aren''t allowed'; end if;
  if new.accent_color is not null and new.accent_color !~ '^#[0-9a-fA-F]{6}$' then new.accent_color := null; end if;
  if new.accent_color2 is not null and new.accent_color2 !~ '^#[0-9a-fA-F]{6}$' then new.accent_color2 := null; end if;
  if tg_op = 'UPDATE' and old.verified_as is not null and new.verified_as is not distinct from old.verified_as
     and (new.username is distinct from old.username or new.display_name is distinct from old.display_name)
     and not public.is_site_admin() and current_user not in ('postgres', 'service_role') then
    handle := lower(regexp_replace(split_part(old.verified_as, ' · ', 2), '[^a-z0-9]', '', 'gi'));
    nm := lower(regexp_replace(coalesce(new.display_name, new.username), '[^a-z0-9]', '', 'gi'));
    if nm <> handle then new.verified_as := null; end if;
  end if;
  return new;
end;
$$;
