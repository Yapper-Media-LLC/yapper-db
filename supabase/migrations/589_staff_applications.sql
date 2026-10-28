-- 589: Staff applications (flag staff_applications, test). A member applies to be a Yapper moderator from Settings
-- (why, active hours, experience, agree to the rules); admins, Management and head mods review in Mod Center, Staff
-- applications. Accepting goes through admin_set_moderator (its checks, the mod badge trigger, the mod_added log row,
-- the head mod daily cap), declining can carry a note the applicant sees. Requirements: account 30+ days old, not
-- banned or muted, not already staff. One waiting application per person; after a decline, 30 days before the next.
-- The applicant hears about the decision live (bc_notice on user:<id>) and on the next app start
-- (my_staff_decision, rows with seen_at null), like join applications (575).
-- Re-runnable.

create table if not exists public.staff_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  why text not null,
  hours text not null,
  experience text not null default '',
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  note text not null default '',
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  -- The applicant saw the decision (the in-app notice).
  seen_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists staff_applications_one_pending on public.staff_applications (user_id)
  where status = 'pending';
create index if not exists staff_applications_pending_idx on public.staff_applications (created_at)
  where status = 'pending';
create index if not exists staff_applications_user_idx on public.staff_applications (user_id, created_at desc);
create index if not exists staff_applications_decided_by_idx on public.staff_applications (decided_by) where decided_by is not null;

alter table public.staff_applications enable row level security;
-- Reads and writes only through the RPCs below.
revoke all on public.staff_applications from public, anon, authenticated;

-- Is the feature on for the caller? Test mode counts the flag's users and members of the flag's servers (there is
-- no server in play here, so feature_on(k, null) would only see the users list).
create or replace function public.staff_apps_on()
returns boolean language plpgsql stable security definer set search_path = public as $$
declare f public.feature_flags;
begin
  select * into f from public.feature_flags where key = 'staff_applications';
  if f.key is null or auth.uid() is null then return false; end if;
  if f.mode = 'everyone' then return true; end if;
  if f.mode <> 'test' then return false; end if;
  return auth.uid() = any(f.users)
      or exists (select 1 from public.server_members where user_id = auth.uid() and server_id = any(f.servers));
end $$;
revoke execute on function public.staff_apps_on() from public, anon;
grant execute on function public.staff_apps_on() to authenticated;

-- Who reviews: admins, Management, head mods (each already needs 2FA through those helpers).
create or replace function public.can_review_staff_apps()
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return public.is_site_admin() or public.is_site_manager() or public.is_head_mod();
end $$;
revoke execute on function public.can_review_staff_apps() from public, anon;
grant execute on function public.can_review_staff_apps() to authenticated;

-- Why the caller can't apply right now, or null if they can. Shared by the form and apply_for_staff.
create or replace function public.staff_apply_block()
returns text language plpgsql stable security definer set search_path = public as $$
declare made timestamptz; last public.staff_applications;
begin
  if auth.uid() is null then return 'Not signed in'; end if;
  if exists (select 1 from public.site_admins where user_id = auth.uid())
     or exists (select 1 from public.site_moderators where user_id = auth.uid())
     or exists (select 1 from public.site_community_managers where user_id = auth.uid()) then
    return 'You''re already on the staff team';
  end if;
  if public.is_site_banned(auth.uid()) then return 'That account is banned'; end if;
  if coalesce((select muted_until > now() from public.profiles where id = auth.uid()), false) then
    return 'You''re timed out right now';
  end if;
  select created_at into made from public.profiles where id = auth.uid();
  if made is null or made > now() - interval '30 days' then
    return 'Your account needs to be at least 30 days old to apply';
  end if;
  select * into last from public.staff_applications where user_id = auth.uid() order by created_at desc limit 1;
  if last.status = 'pending' then return 'You already have an application waiting'; end if;
  if last.status = 'declined' and last.decided_at > now() - interval '30 days' then
    return 'You can apply again ' || to_char(last.decided_at + interval '30 days', 'Mon FMDD');
  end if;
  if last.status = 'withdrawn' and last.decided_at > now() - interval '1 day' then
    return 'You took one back recently. Try again tomorrow';
  end if;
  return null;
end $$;
revoke execute on function public.staff_apply_block() from public, anon;
grant execute on function public.staff_apply_block() to authenticated;

-- What the Settings page needs: is the feature on, can I apply (and why not), and my latest application.
create or replace function public.my_staff_application()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.staff_applications;
begin
  if auth.uid() is null or not public.staff_apps_on() then return jsonb_build_object('on', false); end if;
  select * into a from public.staff_applications where user_id = auth.uid() order by created_at desc limit 1;
  return jsonb_build_object(
    'on', true,
    'block', public.staff_apply_block(),
    'app', case when a.id is null then null else jsonb_build_object(
      'id', a.id, 'status', a.status, 'why', a.why, 'hours', a.hours, 'experience', a.experience, 'note', a.note,
      'created_at', a.created_at, 'decided_at', a.decided_at) end);
end $$;
revoke execute on function public.my_staff_application() from public, anon;
grant execute on function public.my_staff_application() to authenticated;

create or replace function public.apply_for_staff(p_why text, p_hours text, p_experience text default '', p_agree boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare b text; w text := btrim(coalesce(p_why, '')); hr text := btrim(coalesce(p_hours, '')); ex text := btrim(coalesce(p_experience, ''));
        rid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.staff_apps_on() then raise exception 'Staff applications aren''t open yet'; end if;
  -- One at a time per person: two tabs submitting at once would both pass the checks below.
  perform pg_advisory_xact_lock(hashtextextended('staff_apply:' || auth.uid()::text, 0));
  b := public.staff_apply_block();
  if b is not null then raise exception '%', b; end if;
  if not coalesce(p_agree, false) then raise exception 'You need to agree to the rules'; end if;
  if length(w) < 30 then raise exception 'Tell us a bit more about why (30 characters at least)'; end if;
  if length(w) > 1000 or length(ex) > 1000 then raise exception 'Keep each answer under 1000 characters'; end if;
  if hr = '' then raise exception 'Add your timezone and when you''re usually on'; end if;
  if length(hr) > 100 then raise exception 'Keep your timezone and hours under 100 characters'; end if;
  -- An old decision they never dismissed is stale once they apply again.
  update public.staff_applications set seen_at = now() where user_id = auth.uid() and seen_at is null;
  insert into public.staff_applications (user_id, why, hours, experience) values (auth.uid(), w, hr, ex) returning id into rid;
  return rid;
end $$;
revoke execute on function public.apply_for_staff(text, text, text, boolean) from public, anon;
grant execute on function public.apply_for_staff(text, text, text, boolean) to authenticated;

-- Take back a waiting application. Seen right away, so it is never a notice.
create or replace function public.withdraw_staff_application()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update public.staff_applications set status = 'withdrawn', decided_at = now(), seen_at = now()
    where user_id = auth.uid() and status = 'pending';
end $$;
revoke execute on function public.withdraw_staff_application() from public, anon;
grant execute on function public.withdraw_staff_application() to authenticated;

-- The waiting list for reviewers (oldest first), with what helps judge: account age, servers, earlier declines.
create or replace function public.staff_applications_list()
returns table (id uuid, user_id uuid, why text, hours text, experience text, created_at timestamptz,
               joined_at timestamptz, servers int, past_declines int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_review_staff_apps() then raise exception 'Admins, Management and head mods only'; end if;
  return query select a.id, a.user_id, a.why, a.hours, a.experience, a.created_at, p.created_at,
      (select count(*)::int from public.server_members m where m.user_id = a.user_id),
      (select count(*)::int from public.staff_applications d where d.user_id = a.user_id and d.status = 'declined')
    from public.staff_applications a join public.profiles p on p.id = a.user_id
    where a.status = 'pending' order by a.created_at limit 200;
end $$;
revoke execute on function public.staff_applications_list() from public, anon;
grant execute on function public.staff_applications_list() to authenticated;

-- Accept or decline. Accepting makes them a site moderator through admin_set_moderator (who may add mods, bans,
-- Community Managers, "someone above you took them off", the head mod cap, the badge, mod_added in mod_log).
create or replace function public.decide_staff_application(rid uuid, p_accept boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare a public.staff_applications; n text := left(btrim(coalesce(p_note, '')), 300);
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.can_review_staff_apps() then raise exception 'Admins, Management and head mods only'; end if;
  -- Locked: two reviewers deciding at once would both pass the pending check.
  select * into a from public.staff_applications where id = rid for update;
  if a.id is null then raise exception 'That application is gone'; end if;
  if a.status <> 'pending' then raise exception 'Someone already decided that one'; end if;
  if a.user_id = auth.uid() then raise exception 'You can''t decide your own application'; end if;
  if p_accept then
    -- admin_set_moderator re-checks bans but not timeouts, and they may have been muted since applying.
    if coalesce((select muted_until > now() from public.profiles where id = a.user_id), false) then
      raise exception 'They''re timed out right now';
    end if;
    perform public.admin_set_moderator(a.user_id, true, 'Staff application');
  else
    -- Accepts are logged as mod_added by admin_set_moderator; declines go in the Log too.
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'staff_app_declined', a.user_id, n);
  end if;
  update public.staff_applications
    set status = case when p_accept then 'accepted' else 'declined' end, note = n, decided_by = auth.uid(),
        decided_at = now(), seen_at = null
    where id = rid;
  perform public.bc_notice('user:' || a.user_id, 'staff_application', jsonb_build_object(
    'id', rid, 'status', case when p_accept then 'accepted' else 'declined' end, 'note', n));
end $$;
revoke execute on function public.decide_staff_application(uuid, boolean, text) from public, anon;
grant execute on function public.decide_staff_application(uuid, boolean, text) to authenticated;

-- The decision I haven't seen yet (app start). One index read per start.
create or replace function public.my_staff_decision()
returns table (id uuid, status text, note text, decided_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  return query select a.id, a.status, a.note, a.decided_at from public.staff_applications a
    where a.user_id = auth.uid() and a.status in ('accepted', 'declined') and a.seen_at is null
    order by a.decided_at desc limit 1;
end $$;
revoke execute on function public.my_staff_decision() from public, anon;
grant execute on function public.my_staff_decision() to authenticated;

create or replace function public.ack_staff_decision(rid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update public.staff_applications set seen_at = now() where id = rid and user_id = auth.uid() and seen_at is null;
end $$;
revoke execute on function public.ack_staff_decision(uuid) from public, anon;
grant execute on function public.ack_staff_decision(uuid) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('staff_applications', 'Staff applications',
        'Members can apply to be a Yapper moderator from Settings; admins, Management and head mods review in Mod Center, Staff applications.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
