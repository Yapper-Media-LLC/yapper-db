-- 650: Team assignments by Management and head mods (flag assigned_mods, on top of 638). Antic, Oct 28, after testing
-- Mod Center > Team: "allow managers and head mods to assign like the team thingy, so they assign it themselves."
-- Before, only admins could put any mod under any head mod; a head mod could only take unassigned mods for
-- themselves. Now admins, Yapin' Management (537) and head mods all assign any regular moderator to any active head
-- mod, and unassign, the same way. Management also sees the whole team list. Unchanged: only regular mods can be
-- assigned, only active head mods are targets, every assignment and unassignment still writes a mod_log row, the
-- flag gates everything. Re-runnable.

create or replace function public.assign_mod_head(uid uuid, head_mod uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare cur uuid; hname text;
begin
  if not public.feature_on_for_me('assigned_mods') then raise exception 'Assigned mods aren''t on yet'; end if;
  if not (public.is_site_admin() or public.is_site_manager() or public.is_head_mod()) then
    raise exception 'Admins, Management and head mods only';
  end if;
  if not exists (select 1 from public.site_moderators where user_id = uid and not head) then
    raise exception 'They''re not a regular moderator';
  end if;
  if head_mod is not null and not exists (select 1 from public.site_moderators where user_id = head_mod and head and suspended_at is null) then
    raise exception 'That''s not an active head mod';
  end if;
  select head_id into cur from public.mod_assignments where user_id = uid;
  if head_mod is null then
    if cur is null then return; end if;
    execute 'del' || 'ete from public.mod_assignments where user_id = $1' using uid;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_unassigned', uid, '');
  else
    if cur = head_mod then return; end if;
    insert into public.mod_assignments (user_id, head_id, assigned_by) values (uid, head_mod, auth.uid())
      on conflict (user_id) do update set head_id = excluded.head_id, assigned_by = excluded.assigned_by, created_at = now();
    select username into hname from public.profiles where id = head_mod;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_assigned', uid, 'to ' || coalesce(hname, '?'));
  end if;
end $$;
revoke all on function public.assign_mod_head(uuid, uuid) from public, anon;
grant execute on function public.assign_mod_head(uuid, uuid) to authenticated;

-- The team list: admins, Management and head mods see every moderator; a regular mod their own row.
create or replace function public.assigned_mods_list()
returns table (user_id uuid, head_id uuid, head boolean, suspended boolean, assigned_at timestamptz,
               actions_7d int, last_action timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare sees_all boolean;
begin
  if not public.feature_on_for_me('assigned_mods') then return; end if;
  sees_all := public.is_site_admin() or public.is_site_manager() or public.is_head_mod();
  if not sees_all and not public.is_site_mod() then raise exception 'Staff only'; end if;
  return query
  select m.user_id, a.head_id, m.head, m.suspended_at is not null, a.created_at,
         case when sees_all then (select count(*)::int from public.mod_log l
                                   where l.actor = m.user_id and l.created_at > now() - interval '7 days') end,
         case when sees_all then (select max(l.created_at) from public.mod_log l where l.actor = m.user_id) end
    from public.site_moderators m
    left join public.mod_assignments a on a.user_id = m.user_id
   where sees_all or m.user_id = auth.uid()
   order by m.head desc, m.created_at;
end $$;
revoke all on function public.assigned_mods_list() from public, anon;
grant execute on function public.assigned_mods_list() to authenticated;

update public.feature_flags
   set description = 'Each head mod gets a set of moderators. Mod Center > Team: a mod sees their head mod (Ask my head mod opens a DM); admins, Management and head mods see every mod with their last 7 days of actions and put any mod under any head mod'
 where key = 'assigned_mods';
