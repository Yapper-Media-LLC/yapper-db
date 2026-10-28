-- Profile links: web links only (applied live Oct 14). Bug reports da7892d6 / ae56ebe9: javascript: URIs
-- and anything else went straight into profiles.links. The settings page checks too; this is the backstop.
create or replace function public.profile_links_guard()
returns trigger language plpgsql set search_path = public as $$
declare l jsonb;
begin
  if new.links is null then return new; end if;
  if jsonb_typeof(new.links) <> 'array' or jsonb_array_length(new.links) > 5 then raise exception 'Up to five links'; end if;
  for l in select * from jsonb_array_elements(new.links) loop
    if coalesce(l->>'url', '') !~* '^https?://[^\s]{1,200}$' then raise exception 'Links need to start with https://'; end if;
    if length(coalesce(l->>'label', '')) > 40 then raise exception 'Link labels are up to 40 characters'; end if;
  end loop;
  return new;
end; $$;
drop trigger if exists profiles_links_guard on public.profiles;
create trigger profiles_links_guard before insert or update of links on public.profiles
  for each row execute function public.profile_links_guard();
