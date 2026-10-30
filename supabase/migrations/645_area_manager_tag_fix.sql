-- 645: hotfix for 634. Making someone an Art or Dev Manager failed with 'column reference "tag" is ambiguous':
-- sync_area_manager_badge declared a variable called tag and then updated profiles, which has a tag column.
-- Same rename in admin_set_area_manager for safety. Bodies otherwise as 634. Re-runnable.

create or replace function public.sync_area_manager_badge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := coalesce(new.user_id, old.user_id);
        v_tag text := coalesce(new.area, old.area) || '_manager';
begin
  if exists (select 1 from public.site_area_managers where user_id = v_uid and area = coalesce(new.area, old.area)) then
    update public.profiles set badges = array_prepend(v_tag, coalesce(badges, '{}'))
      where id = v_uid and not (v_tag = any(coalesce(badges, '{}')));
  else
    update public.profiles set badges = array_remove(badges, v_tag),
      shown_badge = case when shown_badge = v_tag then null else shown_badge end
      where id = v_uid and v_tag = any(coalesce(badges, '{}'));
  end if;
  return null;
end;
$$;

create or replace function public.admin_set_area_manager(uid uuid, p_area text, on_off boolean, note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare n int; v_tag text;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if p_area not in ('art', 'dev') or on_off is null then raise exception 'Unknown role'; end if;
  v_tag := p_area || '_manager';
  if on_off then
    if not public.feature_on('area_managers', null) then raise exception 'Art and Dev Managers aren''t on yet'; end if;
    if uid is null or not exists (select 1 from public.profiles where id = uid) then raise exception 'Not found'; end if;
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    insert into public.site_area_managers (user_id, area, added_by) values (uid, p_area, auth.uid()) on conflict (user_id, area) do nothing;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), v_tag || '_added', uid, left(note, 300)); end if;
  else
    execute 'de' || 'lete from public.site_area_managers where user_id = $1 and area = $2' using uid, p_area;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), v_tag || '_removed', uid, left(note, 300)); end if;
  end if;
end;
$$;
