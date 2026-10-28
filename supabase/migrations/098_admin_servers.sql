-- Admins: warn a server (notice shown to everyone in it) and shut a server down (no posting, no joining,
-- out of Discovery, reason shown; reversible). Applied live Oct 15. Mod Center → Servers.
alter table public.servers add column if not exists staff_warning text, add column if not exists staff_warned_at timestamptz,
  add column if not exists shut_down_at timestamptz, add column if not exists shut_down_reason text;

create or replace function public.admin_warn_server(sid uuid, msg text)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare own uuid;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select owner_id into own from public.servers where id = sid;
  if own is null then raise exception 'Server not found'; end if;
  update public.servers set staff_warning = nullif(left(trim(coalesce(msg, '')), 500), ''), staff_warned_at = case when nullif(trim(coalesce(msg, '')), '') is null then null else now() end where id = sid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when nullif(trim(coalesce(msg, '')), '') is null then 'server_warning_cleared' else 'server_warned' end, own, left(coalesce(msg, ''), 500) || ' [' || (select name from public.servers where id = sid) || ']');
end; $function$;

create or replace function public.admin_shutdown_server(sid uuid, why text default '', p_on boolean default true)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare own uuid;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select owner_id into own from public.servers where id = sid;
  if own is null then raise exception 'Server not found'; end if;
  if p_on then
    update public.servers set shut_down_at = now(), shut_down_reason = left(coalesce(why, ''), 500),
      locked_until = timestamptz '2999-01-01', lock_reason = 'shut down by Yapper', discoverable = false where id = sid;
  else
    update public.servers set shut_down_at = null, shut_down_reason = null, locked_until = null, lock_reason = null where id = sid;
  end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when p_on then 'server_shutdown' else 'server_reopened' end, own, left(coalesce(why, ''), 500) || ' [' || (select name from public.servers where id = sid) || ']');
end; $function$;

create or replace function public.admin_find_servers(q text)
 returns table (id uuid, name text, owner_id uuid, owner_name text, members int, shut_down_at timestamptz, staff_warning text, discoverable boolean)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.name, s.owner_id, p.username, (select count(*)::int from public.server_members m where m.server_id = s.id), s.shut_down_at, s.staff_warning, s.discoverable
  from public.servers s left join public.profiles p on p.id = s.owner_id
  where public.is_site_admin() and (s.name ilike '%' || coalesce(q, '') || '%' or s.id::text = q or p.username ilike coalesce(q, ''))
  order by (select count(*) from public.server_members m where m.server_id = s.id) desc limit 20;
$function$;
revoke all on function public.admin_warn_server(uuid, text), public.admin_shutdown_server(uuid, text, boolean), public.admin_find_servers(text) from public, anon;
grant execute on function public.admin_warn_server(uuid, text), public.admin_shutdown_server(uuid, text, boolean), public.admin_find_servers(text) to authenticated;
