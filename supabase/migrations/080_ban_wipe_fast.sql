-- Ban + wipe timed out ("canceling statement due to statement timeout"): every removed message fired a live
-- broadcast. broadcast_message_change now skips bulk removals (applied live). This part needs the SQL editor:
create or replace function public.site_ban(uid uuid, why text default '', wipe boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if uid = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;
  perform set_config('statement_timeout', '120s', true);
  insert into public.site_bans (user_id, reason, banned_by) values (uid, left(coalesce(why, ''), 500), auth.uid())
  on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  if wipe then
    perform set_config('yapper.bulk', '1', true);
    delete from public.messages where author_id = uid;
    perform set_config('yapper.bulk', '', true);
  end if;
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now()
   where target_id = uid and status = 'open';
end; $$;
