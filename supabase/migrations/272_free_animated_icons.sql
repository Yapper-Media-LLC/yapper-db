set lock_timeout = '3s';
-- 272: animated server icons are free again (Antic, Oct 18). update_server goes back to its live definition from
-- before 264, and the check 270 added to create_server / create_server_from_template comes out. Re-runnable.
create or replace function public.update_server(sid uuid, server_name text, server_icon text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if server_icon is distinct from (select icon_path from public.servers where id = sid) then
    perform public.check_icon_path(server_icon);
  end if;
  update public.servers set name = btrim(server_name), icon_path = server_icon where id = sid;
end;
$$;

do $$
declare f text; d text; line text := E'\n  if public.supercharge_live() and public.icon_is_animated(server_icon) then raise exception ''Animated icons unlock at Supercharge level 1. Pick a still picture for now''; end if;';
begin
  foreach f in array array['public.create_server(text, text)', 'public.create_server_from_template(text, text, text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position(line in d) = 0 then continue; end if;
    execute replace(d, line, '');
  end loop;
end $$;
reset lock_timeout;
