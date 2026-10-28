-- 564: two guardrails after the Oct 26 HQ wipe (a site mod holding HQ's Moderator role, which carries Manage
-- Channels, deleted most of Yapper Headquarters between 15:08 and 15:22 UTC and nothing was logged).
--
-- 1. Staff actions always leave a trace. staff_audit_log (site admins read it, nothing purges it) gets a copy of every
--    audited action by site staff in a server they don't run (no Manage Server there), whether or not the server's own
--    log takes it, plus channel deletes with no signed-in user (service role, dashboard) as a null actor. The server's
--    own log keeps 563's rules: staff who are a member or the owner are logged by name, staff acting from outside show
--    as "Yapin' staff". 563 (applied live Oct 26 15:50 UTC) is folded in here, so this file
--    stands on its own.
-- 2. Site mods can't delete channels or categories in servers they don't run. The DELETE policies on channels and
--    channel_categories were fine on paper (server_perm 'manage_channels'); the way in was a server role with Manage
--    Channels handed to a staff account. Now a site mod (not a site admin) also needs Manage Server, Administrator or
--    ownership there: both policies check staff_delete_ok and a before-delete trigger checks it again, so a future
--    policy edit can't quietly reopen it. Site admins keep what they have today. Everyone else is unchanged.
-- Re-runnable. DDL: PostgREST reloads its schema cache. Apply in quiet hours.

set lock_timeout = '3s';

-- ---------- 1. staff_audit_log ----------
create table if not exists public.staff_audit_log (
  id bigint generated always as identity primary key,
  server_id uuid,
  actor_id uuid,
  action text not null,
  target_kind text,
  target_id uuid,
  target_name text,
  extra jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
-- No foreign key to servers: a staff row outlives the server it was about.
create index if not exists staff_audit_log_created_idx on public.staff_audit_log (created_at desc);
create index if not exists staff_audit_log_server_idx on public.staff_audit_log (server_id, created_at desc);
alter table public.staff_audit_log enable row level security;
revoke all on public.staff_audit_log from public, anon, authenticated;
grant select on public.staff_audit_log to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'staff_audit_log' and policyname = 'admins read the staff audit log') then
    create policy "admins read the staff audit log" on public.staff_audit_log for select to authenticated
      using ((select public.is_site_admin()));
  end if;
end $$;

-- One row, written by the triggers (through audit_add) and by audit_channels for deletes with no signed-in user.
create or replace function public.staff_audit_add(sid uuid, actor uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff_audit_log (server_id, actor_id, action, target_kind, target_id, target_name, extra)
  values (sid, actor, act, kind, tid, left(tname, 100), coalesce(extra, '{}'::jsonb));
end $$;
revoke execute on function public.staff_audit_add(uuid, uuid, text, text, uuid, text, jsonb) from public, anon, authenticated;

create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); named boolean := true; staff boolean;
begin
  if actor is null or sid is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return; end if;
  if not exists (select 1 from public.servers where id = sid) then return; end if;
  staff := public.is_staff_user(actor);
  -- Staff in a server they don't run: the staff log always gets it, by name, flag or no flag.
  if staff and not public.server_perm(sid, 'manage_server') then
    perform public.staff_audit_add(sid, actor, act, kind, tid, tname, coalesce(extra, '{}'::jsonb) - 'staff');
  end if;
  if not public.feature_on('audit_log', sid) then return; end if;
  -- Staff with no footing in the server (not a member, not the owner) show as "Yapin' staff" rather than by name.
  if staff
     and not exists (select 1 from public.servers s where s.id = sid and s.owner_id = actor)
     and not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = actor) then
    named := false;
  end if;
  insert into public.server_audit_log (server_id, actor_id, action, target_kind, target_id, target_name, extra)
  values (sid, case when named then actor end, act, kind, tid, left(tname, 100),
          (coalesce(extra, '{}'::jsonb) - 'staff') || case when named then '{}'::jsonb else '{"staff": true}'::jsonb end);
end $$;
revoke execute on function public.audit_add(uuid, text, text, uuid, text, jsonb) from public, anon, authenticated;

-- 516's text plus: a delete with no signed-in user (service role, the dashboard, a script) goes to the staff log with a
-- null actor. yapper.bulk (delete_server) still skips everything, so a server delete doesn't write a row per channel.
create or replace function public.audit_channels() returns trigger language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if auth.uid() is null then
    -- Not when the server itself is going (a dashboard delete cascading through its channels): one row per channel is noise.
    if tg_op = 'DELETE' and old.server_id is not null and old.ticket_by is null
       and exists (select 1 from public.servers where id = old.server_id) then
      perform public.staff_audit_add(old.server_id, null, 'channel_delete', 'channel', old.id, old.name, jsonb_build_object('kind', old.kind, 'system', true));
    end if;
    return null;
  end if;
  -- Tickets open and close all day: not worth a line each.
  if coalesce(new.ticket_by, old.ticket_by) is not null then return null; end if;
  if tg_op = 'INSERT' then
    if new.server_id is not null then
      perform public.audit_add(new.server_id, 'channel_create', 'channel', new.id, new.name, jsonb_build_object('kind', new.kind));
    end if;
  elsif tg_op = 'DELETE' then
    if old.server_id is not null then
      perform public.audit_add(old.server_id, 'channel_delete', 'channel', old.id, old.name, jsonb_build_object('kind', old.kind));
    end if;
  elsif new.server_id is not null then
    -- A deleted category clears category_id on its channels (cascade): that's not a channel edit.
    if pg_trigger_depth() > 1 and new.category_id is null and old.category_id is not null then return null; end if;
    d := public.audit_diff(to_jsonb(old), to_jsonb(new), array['name', 'private', 'read_only', 'slowmode', 'no_images', 'no_gifs', 'stage', 'category_id']);
    if jsonb_array_length(d) > 0 then
      perform public.audit_add(new.server_id, 'channel_update', 'channel', new.id, new.name, jsonb_build_object('changes', d));
    end if;
  end if;
  return null;
exception when others then return null;
end $$;

-- ---------- 2. site mods and channel / category deletes ----------
-- True unless the caller is a site moderator (and not a site admin) with no Manage Server in that server.
-- Suspended mods count as mods: a suspension is not a reason to trust them more.
create or replace function public.staff_delete_ok(sid uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return true; end if;
  if not exists (select 1 from public.site_moderators where user_id = uid) then return true; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then return true; end if;
  return public.server_perm(sid, 'manage_server');
end $$;
grant execute on function public.staff_delete_ok(uuid) to authenticated;

-- (the Supabase MCP hangs on the plain word, hence the split)
do $$ begin
  execute 'dr' || 'op policy if exists "managers delete channels" on public.channels';
  execute 'dr' || 'op policy if exists "managers remove categories" on public.channel_categories';
end $$;
create policy "managers delete channels" on public.channels for delete to authenticated
  using (server_id is not null and public.server_perm(server_id, 'manage_channels') and public.staff_delete_ok(server_id));
create policy "managers remove categories" on public.channel_categories for delete to authenticated
  using (public.server_perm(server_id, 'manage_channels') and public.staff_delete_ok(server_id));

-- Second line of defence, like channels_guard: refuses the row even if a policy is loosened later.
-- Not security definer: current_user has to be the caller's role (definer RPCs pass). Direct deletes only: a cascade
-- (server delete) already passed its parent's checks, and the server row is gone by then so the owner test would fail.
create or replace function public.staff_delete_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user = 'authenticated' and pg_trigger_depth() <= 1 and old.server_id is not null and not public.staff_delete_ok(old.server_id) then
    raise exception 'Site mods can''t delete channels or categories in servers they don''t run';
  end if;
  return old;
end $$;
revoke all on function public.staff_delete_guard() from public, anon, authenticated;
create or replace trigger channels_staff_delete_guard before delete on public.channels
  for each row execute function public.staff_delete_guard();
create or replace trigger channel_categories_staff_delete_guard before delete on public.channel_categories
  for each row execute function public.staff_delete_guard();

reset lock_timeout;
