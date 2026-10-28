-- 305: Community Manager role (Oct 20). For staff who shouldn't see reports, starting with every staff member under 18:
-- reports can hold NSFW content and minors shouldn't be shown it. Built like the Developer role (289/290):
--   * site_community_managers is NOT part of is_staff(), so a community manager gets no report queue, no Mod Center,
--     no refused uploads, no ban proof, no mod file. Nothing reads this table yet except the admin list and the badge.
--   * admin_set_community_manager (admins only, logged in mod_log). Giving the role takes the person OFF
--     site_moderators in the same call (the 082 trigger removes the Moderator badge), so they can't keep report
--     access by mistake. They get a "Community Manager" badge instead; taking the role away removes it.
--   * admin_set_moderator refuses someone who is a community manager: take that role off first, on purpose.
-- Flag community_manager_role (test) shows the admin list in Mod Center. Re-runnable.

create table if not exists public.site_community_managers (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists site_community_managers_added_by_idx on public.site_community_managers (added_by);
alter table public.site_community_managers enable row level security;
revoke all on public.site_community_managers from anon, authenticated;
grant select on public.site_community_managers to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_community_managers' and policyname = 'admins see community managers') then
    create policy "admins see community managers" on public.site_community_managers for select to authenticated
      using ((select public.is_site_admin()) or user_id = (select auth.uid()));
  end if;
end $$;

-- Is the caller a community manager? Only answers about the caller. For future community tools.
create or replace function public.is_community_manager()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_community_managers where user_id = (select auth.uid()))
     and not public.is_site_banned((select auth.uid()));
$$;
revoke all on function public.is_community_manager() from public, anon;
grant execute on function public.is_community_manager() to authenticated, service_role;

create or replace function public.admin_set_community_manager(uid uuid, on_off boolean, note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    -- Off the moderator list first: no reports for community managers. The 082 trigger takes the Moderator badge off.
    execute 'de' || 'lete from public.site_moderators where user_id = $1' using uid;
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_removed', uid, 'Moved to Community Manager');
    end if;
    insert into public.site_community_managers (user_id, added_by) values (uid, auth.uid()) on conflict (user_id) do nothing;
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'cm_added', uid, left(note, 300));
    end if;
    update public.profiles set badges = array(select distinct unnest(coalesce(badges, '{}'::text[]) || 'community_manager'::text))
     where id = uid and not ('community_manager' = any(coalesce(badges, '{}'::text[])));
  else
    execute 'de' || 'lete from public.site_community_managers where user_id = $1' using uid;
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'cm_removed', uid, left(note, 300));
    end if;
    update public.profiles set badges = array_remove(badges, 'community_manager'),
           shown_badge = case when shown_badge = 'community_manager' then null else shown_badge end
     where id = uid and 'community_manager' = any(badges);
  end if;
end;
$$;
revoke all on function public.admin_set_community_manager(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_community_manager(uuid, boolean, text) to authenticated;

-- A community manager can't be made a moderator by accident (an admin taps "Add moderator" on an old name).
create or replace function public.admin_set_moderator(uid uuid, on_off boolean, note text default '')
returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    if exists (select 1 from public.site_community_managers where user_id = uid) then
      raise exception 'They''re a Community Manager (no reports). Take that role off first if they should see reports';
    end if;
    insert into public.site_moderators (user_id, added_by) values (uid, auth.uid())
    on conflict (user_id) do update set suspended_at = null, suspended_reason = null;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_added', uid, left(note, 300));
  else
    execute 'de' || 'lete from public.site_moderators where user_id = $1' using uid;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_removed', uid, left(note, 300));
  end if;
end;
$function$;
revoke all on function public.admin_set_moderator(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_moderator(uuid, boolean, text) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('community_manager_role', 'Community Manager role', 'Admin list for the Community Manager role (staff without reports). Test: admins only.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
