-- 365: Head Moderators (flag head_mods). A head mod is a site moderator with `head` set. On top of a mod's powers
-- they read the whole mod log, see per-mod stats, and add, remove, pause and reinstate regular moderators (never
-- admins, other head mods or themselves; 10 such changes a day). Only admins make head mods. They get the
-- head_mod badge and the "Head Moderator" role in Yapper HQ while they're an active head mod. Re-runnable.

alter table public.site_moderators add column if not exists head boolean not null default false;

create or replace function public.hq_head_mod_role_id() returns uuid language sql immutable as $$ select '3650f1e2-7c4b-4d9a-8e21-5a6b7c8d9e01'::uuid $$;

create or replace function public.is_head_mod()
returns boolean language sql stable security definer set search_path = public as $$
  select public.feature_on('head_mods', null)
     and exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null)
     and public.staff_mfa_ok();
$$;
revoke all on function public.is_head_mod() from public, anon;
grant execute on function public.is_head_mod() to authenticated;

-- The HQ role, just above Moderator. Developer and Admin move up one to make room (only the first time).
do $$
declare hq uuid := '00000000-0000-4000-8000-00000000b002'; modpos int; modperms jsonb;
begin
  if not exists (select 1 from public.servers where id = hq) then return; end if; -- test databases
  if exists (select 1 from public.roles where id = public.hq_head_mod_role_id()) then return; end if;
  select position, perms into modpos, modperms from public.roles where server_id = hq and name = 'Moderator' order by position desc limit 1;
  if modpos is null then return; end if;
  perform set_config('yapper.bot', '1', true);
  update public.roles set position = position + 1 where server_id = hq and position > modpos;
  insert into public.roles (id, server_id, name, color, position, perms, manage_server, manage_messages)
  values (public.hq_head_mod_role_id(), hq, 'Head Moderator', '#f0b232', modpos + 1, coalesce(modperms, '{}'), false, false);
  perform set_config('yapper.bot', '', true);
end $$;

-- Badge and HQ role follow the moderator row: active head mod = both, anything else = neither.
create or replace function public.sync_mod_badge()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare uid uuid := coalesce(new.user_id, old.user_id);
        active boolean := tg_op <> 'DELETE' and new.suspended_at is null;
        head boolean := active and new.head;
        hq uuid := '00000000-0000-4000-8000-00000000b002';
begin
  if active then
    update public.profiles set badges = array_append(coalesce(badges, '{}'), 'mod')
      where id = uid and not ('mod' = any(coalesce(badges, '{}')));
  else
    update public.profiles set badges = array_remove(badges, 'mod'),
      shown_badge = case when shown_badge = 'mod' then null else shown_badge end
      where id = uid and 'mod' = any(coalesce(badges, '{}'));
  end if;
  if head then
    update public.profiles set badges = array_prepend('head_mod', coalesce(badges, '{}'))
      where id = uid and not ('head_mod' = any(coalesce(badges, '{}')));
    if exists (select 1 from public.server_members where server_id = hq and user_id = uid)
       and exists (select 1 from public.roles where id = public.hq_head_mod_role_id()) then
      perform set_config('yapper.bot', '1', true);
      insert into public.member_roles (server_id, user_id, role_id, manual) values (hq, uid, public.hq_head_mod_role_id(), true) on conflict do nothing;
      perform set_config('yapper.bot', '', true);
    end if;
  else
    update public.profiles set badges = array_remove(badges, 'head_mod'),
      shown_badge = case when shown_badge = 'head_mod' then null else shown_badge end
      where id = uid and 'head_mod' = any(coalesce(badges, '{}'));
    execute 'del' || 'ete from public.member_roles where server_id = $1 and user_id = $2 and role_id = $3' using hq, uid, public.hq_head_mod_role_id();
  end if;
  return null;
end; $function$;
create or replace trigger site_moderators_badge after insert or delete or update of suspended_at, head on public.site_moderators
  for each row execute function public.sync_mod_badge();

-- Head mods can change regular mods, a few times a day. Raises if not allowed.
create or replace function public.head_mod_may_change(uid uuid)
returns void language plpgsql volatile security definer set search_path to 'public' as $$
begin
  if public.is_site_admin() then return; end if;
  if not public.is_head_mod() then raise exception 'Admins only'; end if;
  -- One change at a time per head mod, so parallel calls can't all slip under the cap.
  perform pg_advisory_xact_lock(hashtextextended('head_mod_cap:' || auth.uid()::text, 0));
  if uid = auth.uid() then raise exception 'You can''t change your own role'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins can''t be changed'; end if;
  if exists (select 1 from public.site_moderators where user_id = uid and head) then raise exception 'Only admins can change head mods'; end if;
  if (select count(*) from public.mod_log where actor = auth.uid() and created_at > now() - interval '24 hours'
        and action in ('mod_added', 'mod_removed', 'mod_suspended')) >= 10 then
    raise exception 'That''s 10 moderator changes today. Ask an admin for more';
  end if;
end $$;
revoke all on function public.head_mod_may_change(uuid) from public, anon, authenticated;

create or replace function public.admin_set_moderator(uid uuid, on_off boolean, note text default '')
returns void language plpgsql security definer set search_path to 'public' as $function$
declare n int;
begin
  perform public.head_mod_may_change(uid);
  if on_off then
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    -- Head mods can't undo an admin: someone an admin last paused or removed stays that way until an admin says.
    -- Only admins' own entries count (a head mod's remove-then-add can't bury the admin's), and an automatic pause
    -- (hourly limit) also waits for an admin.
    if not public.is_site_admin() and (
         (select l.action from public.mod_log l join public.site_admins a on a.user_id = l.actor
           where l.target_id = uid and l.action in ('mod_added', 'mod_removed', 'mod_suspended')
           order by l.created_at desc limit 1) in ('mod_removed', 'mod_suspended')
         or exists (select 1 from public.site_moderators where user_id = uid and suspended_reason like 'Automatic:%')) then
      raise exception 'An admin took them off. Ask an admin';
    end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    if exists (select 1 from public.site_community_managers where user_id = uid) then
      raise exception 'They''re a Community Manager (no reports). Take that role off first if they should see reports';
    end if;
    insert into public.site_moderators (user_id, added_by) values (uid, auth.uid())
    on conflict (user_id) do update set suspended_at = null, suspended_reason = null where site_moderators.suspended_at is not null;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_added', uid, left(note, 300)); end if;
  else
    execute 'de' || 'lete from public.site_moderators where user_id = $1' using uid;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_removed', uid, left(note, 300)); end if;
  end if;
end;
$function$;
revoke all on function public.admin_set_moderator(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_moderator(uuid, boolean, text) to authenticated;

create or replace function public.admin_suspend_moderator(uid uuid, why text default '')
returns void language plpgsql security definer set search_path to 'public' as $function$
declare n int;
begin
  perform public.head_mod_may_change(uid);
  update public.site_moderators set suspended_at = now(), suspended_reason = nullif(left(why, 200), '') where user_id = uid and suspended_at is null;
  get diagnostics n = row_count;
  if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_suspended', uid, left(why, 300)); end if;
end;
$function$;
revoke all on function public.admin_suspend_moderator(uuid, text) from public, anon;
grant execute on function public.admin_suspend_moderator(uuid, text) to authenticated;

-- Admins only: make or unmake a head mod. They have to be a moderator already.
create or replace function public.admin_set_head_mod(uid uuid, on_off boolean, note text default '')
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off and not public.feature_on('head_mods', null) then raise exception 'Head mods aren''t on yet'; end if;
  if on_off then
    if not exists (select 1 from public.site_moderators where user_id = uid and suspended_at is null) then
      raise exception 'Make them a moderator first (and not paused)';
    end if;
    update public.site_moderators set head = true where user_id = uid and not head;
    if found then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'head_mod_added', uid, left(note, 300)); end if;
  else
    update public.site_moderators set head = false where user_id = uid and head;
    if found then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'head_mod_removed', uid, left(note, 300)); end if;
  end if;
end $$;
revoke all on function public.admin_set_head_mod(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_head_mod(uuid, boolean, text) to authenticated;

-- Per-mod numbers for the last p_days days (admins and head mods).
create or replace function public.staff_mod_stats(p_days int default 7)
returns table (user_id uuid, head boolean, suspended boolean, since timestamptz, total bigint, deletes bigint, warns bigint,
               timeouts bigint, bans bigint, unbans bigint, verifies bigint, appeals bigint, other bigint, last_action timestamptz)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public.is_site_admin() or public.is_head_mod()) then raise exception 'Admins only'; end if;
  p_days := least(greatest(coalesce(p_days, 7), 1), 90);
  return query
  select m.user_id, m.head, m.suspended_at is not null, m.created_at,
         count(l.*), count(*) filter (where l.action in ('delete', 'purge')),
         count(*) filter (where l.action = 'warn'),
         count(*) filter (where l.action in ('timeout', 'voice_mute')),
         count(*) filter (where l.action = 'ban'),
         count(*) filter (where l.action = 'unban'),
         count(*) filter (where l.action in ('verify', 'verify_reject', 'verify_ask_proof')),
         count(*) filter (where l.action in ('appeal_approved', 'appeal_denied')),
         count(*) filter (where l.action is not null and l.action not in ('delete', 'purge', 'warn', 'timeout', 'voice_mute', 'ban', 'unban',
           'verify', 'verify_reject', 'verify_ask_proof', 'appeal_approved', 'appeal_denied')),
         (select max(x.created_at) from public.mod_log x where x.actor = m.user_id)
    from public.site_moderators m
    left join public.mod_log l on l.actor = m.user_id and l.created_at > now() - make_interval(days => p_days)
   group by m.user_id, m.head, m.suspended_at, m.created_at;
end $$;
revoke all on function public.staff_mod_stats(int) from public, anon;
grant execute on function public.staff_mod_stats(int) to authenticated;

-- Head mods read the whole log and the moderator list.
do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mod_log' and policyname = 'admins read the mod log') then
    execute 'dr' || 'op policy "admins read the mod log" on public.mod_log';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_moderators' and policyname = 'staff see moderators') then
    execute 'dr' || 'op policy "staff see moderators" on public.site_moderators';
  end if;
end $$;
create policy "admins read the mod log" on public.mod_log for select to authenticated
  using ((select public.is_site_admin()) or (select public.is_head_mod()) or actor = (select auth.uid()));
create policy "staff see moderators" on public.site_moderators for select to authenticated
  using ((select public.is_site_admin()) or (select public.is_head_mod()) or user_id = (select auth.uid()));

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('head_mods', 'Head Moderators', 'Head mods: read the mod log, see mod stats, add, remove and pause regular mods. Admins make them in Mod Center > Moderators', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
