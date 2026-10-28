-- 226: removing a warning failed with 'record "w" has no field "by"'. "by" is an SQL keyword, so inside an
-- expression w.by didn't resolve to the column. Quote it. Re-runnable.
create or replace function public.mod_remove_warning(wid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare w public.user_warnings;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into w from public.user_warnings where id = wid;
  if w.id is null or w.removed_at is not null then raise exception 'That warning is already gone'; end if;
  if not public.is_site_admin() and w."by" is distinct from auth.uid() then raise exception 'Only the moderator who gave it (or an admin) can remove it'; end if;
  perform public.mod_guard('unwarn', w.user_id, null);
  update public.user_warnings set removed_at = now(), removed_by = auth.uid(), seen_at = coalesce(seen_at, now()) where id = wid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unwarn', w.user_id, left('Removed warning: ' || w.reason, 300));
end $function$;
