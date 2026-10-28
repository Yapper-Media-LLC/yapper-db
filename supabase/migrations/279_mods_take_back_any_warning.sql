set lock_timeout = '3s';
-- 279: any moderator can take back any warning and reset someone's standing (Vspcoderz, Oct 19: "we can't reset the
-- acc standing, only u can do it"). Before, a moderator could only remove warnings they gave themselves, so a false
-- warning from another mod stayed until an admin cleared it. mod_guard still applies (rate limit, and moderators
-- can't act on staff), and every removal is in the mod log with who did it.
-- Live definitions (pg_get_functiondef, Oct 19) minus the "only the mod who gave it" checks. Re-runnable.

create or replace function public.mod_remove_warning(wid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare w public.user_warnings;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into w from public.user_warnings where id = wid;
  if w.id is null or w.removed_at is not null then raise exception 'That warning is already gone'; end if;
  perform public.mod_guard('unwarn', w.user_id, null);
  update public.user_warnings set removed_at = now(), removed_by = auth.uid(), seen_at = coalesce(seen_at, now()) where id = wid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unwarn', w.user_id, left('Removed warning: ' || w.reason, 300));
end $$;

create or replace function public.mod_reset_standing(uid uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  perform public.mod_guard('unwarn', uid, null);
  with gone as (
    update public.user_warnings set removed_at = now(), removed_by = auth.uid(), seen_at = coalesce(seen_at, now())
    where user_id = uid and removed_at is null returning 1)
  select count(*) into n from gone;
  if n > 0 then
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unwarn', uid, 'Reset standing: removed ' || n || ' warning' || case when n = 1 then '' else 's' end);
  end if;
  return n;
end $$;
revoke all on function public.mod_reset_standing(uuid) from public, anon;
grant execute on function public.mod_reset_standing(uuid) to authenticated;
reset lock_timeout;
