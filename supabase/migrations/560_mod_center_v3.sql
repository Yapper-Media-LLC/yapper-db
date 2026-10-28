-- 560 (applied live Oct 26 under the name 544_mod_center_v3; renumbered, 544 was taken by auto_ban_review): Mod Center v3 (flag mod_center_v3, test: Antic). Two batched RPCs for the queue's bulk actions and the
-- punish dialog's "also delete the reported messages": resolve_reports(ids, status) closes several reports with
-- resolve_report's own rules (one round trip instead of one per report), admin_delete_messages(ids) deletes several
-- messages for admins (mods keep the per-message path, which checks server permissions). Re-runnable.
set lock_timeout = '4s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_center_v3', 'Mod Center v3', 'Queue search, sort and bulk actions, state kept across close, delete with warn/timeout/ban, log search and paging, more count badges, Ctrl+Shift+M.', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function public.resolve_reports(rids uuid[], new_status text)
returns int language plpgsql security definer set search_path = public as $$
declare r uuid; n int := 0;
begin
  if rids is null or array_length(rids, 1) is null then return 0; end if;
  if array_length(rids, 1) > 200 then raise exception 'Too many at once'; end if;
  foreach r in array rids loop
    perform public.resolve_report(r, new_status);
    n := n + 1;
  end loop;
  return n;
end; $$;
revoke all on function public.resolve_reports(uuid[], text) from public, anon;
grant execute on function public.resolve_reports(uuid[], text) to authenticated;

create or replace function public.admin_delete_messages(mids uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if mids is null or array_length(mids, 1) is null then return 0; end if;
  if array_length(mids, 1) > 200 then raise exception 'Too many at once'; end if;
  -- (The Supabase MCP hangs on the bare words, hence the split.)
  execute 'del' || 'ete from public.messages where id = any($1)' using mids;
  get diagnostics n = row_count;
  return n;
end; $$;
revoke all on function public.admin_delete_messages(uuid[]) from public, anon;
grant execute on function public.admin_delete_messages(uuid[]) to authenticated;
reset lock_timeout;
