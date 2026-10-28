-- IP loggers / link trackers are blocked like adult sites, and profile + server link lists are checked too.
-- (domains inserted into blocked_domains live; see no_adult_links + triggers profiles_no_bad_links / servers_no_bad_links)
create or replace trigger profiles_no_bad_links before insert or update of links on public.profiles
  for each row execute function public.no_adult_links('links');
create or replace trigger servers_no_bad_links before insert or update of links on public.servers
  for each row execute function public.no_adult_links('links');

-- Server links never saved (no update policy on servers): saved through an RPC now.
create or replace function public.set_server_links(sid uuid, p_links jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can edit links'; end if;
  if jsonb_typeof(p_links) <> 'array' or jsonb_array_length(p_links) > 10 then raise exception 'Up to 10 links'; end if;
  update public.servers set links = p_links where id = sid;
end; $$;
revoke all on function public.set_server_links(uuid, jsonb) from public, anon;
grant execute on function public.set_server_links(uuid, jsonb) to authenticated;
