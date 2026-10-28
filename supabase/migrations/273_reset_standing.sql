set lock_timeout = '3s';
-- 273: "we unwarned them and they're still limited" (Minecraft, Oct 19). Account standing counts every active warning
-- from the last 90 days, so taking back one of two leaves the person limited, and the mod's user file said
-- "Good standing" anyway (it only looked at bans and timeouts). The app now shows the real tier there, and this
-- clears all of someone's active warnings in one go: admins any, moderators only when they gave all of them.
-- Re-runnable.
create or replace function public.mod_reset_standing(uid uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.is_site_admin() and exists (
    select 1 from public.user_warnings w where w.user_id = uid and w.removed_at is null and w."by" is distinct from auth.uid()) then
    raise exception 'Some of these warnings were given by someone else. Ask them or an admin to take those back';
  end if;
  perform public.mod_guard('unwarn', uid, null);
  with gone as (
    update public.user_warnings set removed_at = now(), removed_by = auth.uid(), seen_at = coalesce(seen_at, now())
    where user_id = uid and removed_at is null and (public.is_site_admin() or "by" = auth.uid()) returning 1)
  select count(*) into n from gone;
  if n > 0 then
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unwarn', uid, 'Reset standing: removed ' || n || ' warning' || case when n = 1 then '' else 's' end);
  end if;
  return n;
end $$;
revoke all on function public.mod_reset_standing(uuid) from public, anon;
grant execute on function public.mod_reset_standing(uuid) to authenticated;
reset lock_timeout;
