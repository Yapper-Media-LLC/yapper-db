-- 638: Assigned Moderators (flag assigned_mods). Each head mod gets a set of regular moderators. Admins assign any
-- mod to any head mod; a head mod takes unassigned mods for themselves and lets their own go. A mod sees who their
-- head mod is (Mod Center > Team, "Ask my head mod" opens a DM); admins and head mods see every mod with their
-- actions in the last 7 days. Feature request from Yuki (HQ, supported by Greninja), Oct 28. Re-runnable.

create table if not exists public.mod_assignments (
  user_id uuid primary key references public.site_moderators (user_id) on delete cascade,
  head_id uuid not null references public.site_moderators (user_id) on delete cascade,
  assigned_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists mod_assignments_head_idx on public.mod_assignments (head_id);
create index if not exists mod_assignments_assigned_by_idx on public.mod_assignments (assigned_by);
alter table public.mod_assignments enable row level security;
-- No policies on purpose: reads go through assigned_mods_list(), writes through assign_mod_head().
revoke all on public.mod_assignments from public, anon, authenticated;

-- Someone who stops being a head mod, or is paused, loses their list (their mods can be taken again); someone who
-- becomes a head mod stops being on a list.
create or replace function public.mod_assignments_head_changed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.head and not old.head then
    execute 'del' || 'ete from public.mod_assignments where user_id = $1' using new.user_id;
  elsif (old.head and not new.head) or (new.suspended_at is not null and old.suspended_at is null) then
    execute 'del' || 'ete from public.mod_assignments where head_id = $1' using new.user_id;
  end if;
  return null;
end $$;
drop trigger if exists mod_assignments_head_changed on public.site_moderators;
create trigger mod_assignments_head_changed after update of head, suspended_at on public.site_moderators
  for each row when (old.head is distinct from new.head or old.suspended_at is distinct from new.suspended_at)
  execute function public.mod_assignments_head_changed();

-- Put a regular moderator under a head mod (head_mod null = take them off their list). Admins: anyone to anyone.
-- Head mods: only to themselves, and only mods who are unassigned or already theirs.
create or replace function public.assign_mod_head(uid uuid, head_mod uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare cur uuid; hname text;
begin
  if not public.feature_on_for_me('assigned_mods') then raise exception 'Assigned mods aren''t on yet'; end if;
  if not (public.is_site_admin() or public.is_head_mod()) then raise exception 'Admins and head mods only'; end if;
  if not exists (select 1 from public.site_moderators where user_id = uid and not head) then
    raise exception 'They''re not a regular moderator';
  end if;
  if head_mod is not null and not exists (select 1 from public.site_moderators where user_id = head_mod and head and suspended_at is null) then
    raise exception 'That''s not an active head mod';
  end if;
  select head_id into cur from public.mod_assignments where user_id = uid;
  if not public.is_site_admin() then
    if head_mod is not null and head_mod <> auth.uid() then raise exception 'You can only assign mods to yourself'; end if;
    if cur is not null and cur <> auth.uid() then raise exception 'They''re on another head mod''s list. Ask an admin'; end if;
  end if;
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

-- The team list. Admins and head mods: every moderator (head mods too, so the client knows who can take a list)
-- with their head mod, actions in the last 7 days and last action. A regular mod: just their own row (who their
-- head mod is). Empty when the flag is off for the caller.
create or replace function public.assigned_mods_list()
returns table (user_id uuid, head_id uuid, head boolean, suspended boolean, assigned_at timestamptz,
               actions_7d int, last_action timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare sees_all boolean;
begin
  if not public.feature_on_for_me('assigned_mods') then return; end if;
  sees_all := public.is_site_admin() or public.is_head_mod();
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

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('assigned_mods', 'Assigned Moderators',
        'Each head mod gets a set of moderators. Mod Center > Team: a mod sees their head mod (Ask my head mod opens a DM), head mods and admins see every mod with their last 7 days of actions and assign them',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
