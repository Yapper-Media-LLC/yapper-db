-- 563: staff actions in a server always reach its audit log. Antic, Oct 26: "fix audit_add so site staff actions in
-- a server are always logged".
-- 232 kept Yapper staff out of a server's log unless they had Manage Server there, so a site mod who also held a
-- server role (HQ's Moderator role has Manage Channels) could delete channels with no trace: that's how HQ lost
-- seven channels on 26 Oct with an empty log. Now:
-- * a staffer who is a member of that server (joined, holds a role, or owns it) is logged as themselves, like any member;
-- * a staffer acting purely by staff power (a takedown in a server they're not part of) is logged too, as
--   "Yapin' staff" (actor_id null, extra.staff = true), so the server sees what happened without the person's name.
-- Nothing else changes: system and bulk work still skip, the flag and the 90-day keep stay.
-- Re-runnable; data only in the sense that it replaces one function.

create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); named boolean := true;
begin
  if actor is null or sid is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return; end if;
  if not exists (select 1 from public.servers where id = sid) then return; end if;
  if not public.feature_on('audit_log', sid) then return; end if;
  -- Staff with no footing in the server (not a member, not the owner) show as "Yapin' staff" rather than by name.
  if public.is_staff_user(actor)
     and not exists (select 1 from public.servers s where s.id = sid and s.owner_id = actor)
     and not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = actor) then
    named := false;
  end if;
  insert into public.server_audit_log (server_id, actor_id, action, target_kind, target_id, target_name, extra)
  values (sid, case when named then actor end, act, kind, tid, left(tname, 100),
          (coalesce(extra, '{}'::jsonb) - 'staff') || case when named then '{}'::jsonb else '{"staff": true}'::jsonb end);
end $$;
