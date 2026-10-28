-- 290: Developer badge. People with the Developer role (289, site_developers) get a "Developer" badge, so it shows
-- on their profile like Moderator does. It comes and goes with the role: admin_set_developer adds it when the role is
-- given and takes it off when the role is taken away. Admins can also hand it out or remove it by hand
-- (admin_set_badge now knows 'developer'; moderators still only get bug_hunter). Everyone who has the role now gets
-- the badge once. Re-runnable.

create or replace function public.admin_set_badge(uid uuid, badge text, on_off boolean)
returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  if not (public.is_site_admin() or (public.is_site_mod() and badge = 'bug_hunter')) then raise exception 'Admins only'; end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff', 'developer') then raise exception 'Unknown badge'; end if;
  perform public.mod_guard('badge', uid, null);
  update public.profiles set badges = case when on_off then array(select distinct unnest(coalesce(badges, '{}'::text[]) || badge)) else array_remove(badges, badge) end where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;

create or replace function public.admin_set_developer(uid uuid, on_off boolean, note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    insert into public.site_developers (user_id, added_by) values (uid, auth.uid()) on conflict (user_id) do nothing;
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'dev_added', uid, left(note, 300));
    end if;
    update public.profiles set badges = array(select distinct unnest(coalesce(badges, '{}'::text[]) || 'developer'::text))
     where id = uid and not ('developer' = any(coalesce(badges, '{}'::text[])));
  else
    execute 'de' || 'lete from public.site_developers where user_id = $1' using uid;
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'dev_removed', uid, left(note, 300));
    end if;
    update public.profiles set badges = array_remove(badges, 'developer'),
           shown_badge = case when shown_badge = 'developer' then null else shown_badge end
     where id = uid and 'developer' = any(badges);
  end if;
end;
$$;
revoke all on function public.admin_set_developer(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_developer(uuid, boolean, text) to authenticated;
revoke all on function public.admin_set_badge(uuid, text, boolean) from public, anon;
grant execute on function public.admin_set_badge(uuid, text, boolean) to authenticated;

-- Everyone who already has the role.
update public.profiles p set badges = array(select distinct unnest(coalesce(p.badges, '{}'::text[]) || 'developer'::text))
 where p.id in (select user_id from public.site_developers) and not ('developer' = any(coalesce(p.badges, '{}'::text[])));
