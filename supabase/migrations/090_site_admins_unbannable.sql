-- Site admins can't be banned from servers (they need to get in to moderate). Server mods can still kick.
create or replace function public.no_ban_site_admins()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.site_admins where user_id = new.user_id) then
    raise exception 'Yapper admins can''t be banned from servers';
  end if;
  return new;
end $$;
create or replace trigger server_bans_no_site_admins before insert on public.server_bans
  for each row execute function public.no_ban_site_admins();
