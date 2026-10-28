-- ============================================================
-- Yapper · Moderator role (applied to production 2026-10-13)
-- A Yapper-wide moderator can see the report queues, delete messages, time
-- people out (<= 24h), ban (7 days until an admin confirms) and moderate voice.
-- Safeguards: can't touch staff, reason required, hourly limits that pause the
-- role automatically, everything logged in mod_log, admins can undo.
-- ============================================================

create table if not exists public.site_moderators (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  suspended_at timestamptz,
  suspended_reason text
);
alter table public.site_moderators enable row level security;
drop policy if exists "staff see moderators" on public.site_moderators;
create policy "staff see moderators" on public.site_moderators for select to authenticated
  using (public.is_site_admin() or user_id = auth.uid());

create or replace function public.is_site_mod()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.is_staff_user(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$$;

create table if not exists public.mod_log (
  id uuid primary key default gen_random_uuid(),
  actor uuid references public.profiles (id) on delete set null,
  action text not null,
  target_id uuid references public.profiles (id) on delete set null,
  message_id uuid,
  reason text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists mod_log_actor_idx on public.mod_log (actor, created_at desc);
create index if not exists mod_log_time_idx on public.mod_log (created_at desc);
alter table public.mod_log enable row level security;
drop policy if exists "admins read the mod log" on public.mod_log;
create policy "admins read the mod log" on public.mod_log for select to authenticated using (public.is_site_admin() or actor = auth.uid());

alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_site_banned(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;

create or replace function public.mod_guard(action text, target uuid, why text)
returns void language plpgsql security definer set search_path = public as $$
declare n int; lim int;
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action when 'ban' then 15 when 'timeout' then 40 else 150 end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = mod_guard.action and created_at > now() - interval '1 hour';
  if n >= lim then
    update public.site_moderators set suspended_at = now(), suspended_reason = 'Automatic: more than ' || lim || ' ' || action || 's in an hour' where user_id = auth.uid();
    insert into public.mod_log (actor, action, reason) values (auth.uid(), 'auto_suspended', 'More than ' || lim || ' ' || action || 's in an hour');
    raise exception 'You''ve hit the hourly limit for that; your moderator powers are paused until an admin reviews.';
  end if;
end;
$$;

drop policy if exists "yapper moderators delete messages" on public.messages;
create policy "yapper moderators delete messages" on public.messages for delete to authenticated using (public.is_site_mod());
create or replace function public.log_mod_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and old.author_id <> auth.uid() and public.is_site_mod() and not public.is_site_admin() then
    perform public.mod_guard('delete', old.author_id, '');
    insert into public.mod_log (actor, action, target_id, message_id, reason) values (auth.uid(), 'delete', old.author_id, old.id, left(coalesce(old.content, ''), 120));
  end if;
  return old;
end;
$$;
drop trigger if exists messages_log_mod_delete on public.messages;
create trigger messages_log_mod_delete before delete on public.messages for each row execute function public.log_mod_delete();

create or replace function public.mod_timeout(uid uuid, minutes int, why text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.mod_guard('timeout', uid, why);
  if minutes < 1 or (minutes > 1440 and not public.is_site_admin()) then raise exception 'Timeouts are 1 minute to 24 hours'; end if;
  update public.profiles set muted_until = now() + make_interval(mins => minutes), muted_reason = left(why, 200) where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'timeout', uid, minutes || ' min: ' || left(why, 300));
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now() where target_id = uid and status = 'open';
end;
$$;

create or replace function public.mod_ban(uid uuid, why text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.mod_guard('ban', uid, why);
  insert into public.site_bans (user_id, reason, banned_by, expires_at)
  values (uid, left(why, 500), auth.uid(), case when public.is_site_admin() then null else now() + interval '7 days' end)
  on conflict (user_id) do nothing;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'ban', uid, left(why, 300));
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now() where target_id = uid and status = 'open';
end;
$$;

create or replace function public.admin_set_moderator(uid uuid, on_off boolean, note text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    insert into public.site_moderators (user_id, added_by) values (uid, auth.uid())
    on conflict (user_id) do update set suspended_at = null, suspended_reason = null;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_added', uid, left(note, 300));
  else
    delete from public.site_moderators where user_id = uid;
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_removed', uid, left(note, 300));
  end if;
end;
$$;
create or replace function public.admin_suspend_moderator(uid uuid, why text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.site_moderators set suspended_at = now(), suspended_reason = nullif(left(why, 200), '') where user_id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_suspended', uid, left(why, 300));
end;
$$;
create or replace function public.admin_confirm_ban(uid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.site_bans set expires_at = null where user_id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'ban_confirmed', uid, '');
end;
$$;
create or replace function public.admin_clear_timeout(uid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  update public.profiles set muted_until = null, muted_reason = null, voice_muted_until = null where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'timeout_cleared', uid, '');
end;
$$;
revoke all on function public.mod_ban(uuid, text), public.mod_timeout(uuid, int, text), public.admin_set_moderator(uuid, boolean, text),
  public.admin_suspend_moderator(uuid, text), public.admin_confirm_ban(uuid), public.admin_clear_timeout(uuid), public.mod_guard(text, uuid, text) from public, anon;
grant execute on function public.mod_ban(uuid, text), public.mod_timeout(uuid, int, text), public.admin_set_moderator(uuid, boolean, text),
  public.admin_suspend_moderator(uuid, text), public.admin_confirm_ban(uuid), public.admin_clear_timeout(uuid) to authenticated;

drop policy if exists "moderators read reports" on public.reports;
create policy "moderators read reports" on public.reports for select to authenticated using (public.is_site_mod());
drop policy if exists "moderators read bans" on public.site_bans;
create policy "moderators read bans" on public.site_bans for select to authenticated using (public.is_site_mod());

create or replace function public.resolve_report(rid uuid, new_status text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.reports where id = rid;
  if not (public.is_staff() or (sid is not null and public.server_perm(sid, 'manage_server'))) then raise exception 'Not allowed'; end if;
  if new_status not in ('open', 'actioned', 'dismissed') then raise exception 'Bad status'; end if;
  update public.reports
     set status = new_status,
         resolved_by = case when new_status = 'open' then null else auth.uid() end,
         resolved_at = case when new_status = 'open' then null else now() end
   where id = rid;
end;
$$;

create or replace function public.voice_timeout(uid uuid, vchannel uuid, minutes int)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.channels where id = vchannel;
  if not (public.is_staff() or (sid is not null and public.server_perm(sid, 'manage_server'))) then raise exception 'Not allowed'; end if;
  if public.is_staff_user(uid) and not public.is_site_admin() then raise exception 'You can''t mute staff'; end if;
  update public.profiles set voice_muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end where id = uid;
  if not public.is_site_admin() then
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'voice_mute', uid, minutes || ' min');
  end if;
end;
$$;

create or replace function public.triage_open_reports()
returns table (closed int, flagged int)
language plpgsql security definer set search_path = public as $$
declare r public.reports; t record; c int := 0; f int := 0;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  for r in select * from public.reports where status = 'open' loop
    select * into t from public.triage_rules(r);
    if t.status <> 'open' then
      update public.reports set status = t.status, triage = 'auto', triage_note = t.note, resolved_at = now() where id = r.id;
      c := c + 1;
    else
      update public.reports set triage = t.triage, triage_note = t.note where id = r.id and (triage is distinct from t.triage or triage_note is distinct from t.note);
      if t.triage = 'ban' then f := f + 1; end if;
    end if;
  end loop;
  return query select c, f;
end;
$$;
