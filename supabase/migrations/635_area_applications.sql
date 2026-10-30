-- 635: Art Manager and Dev Manager applications (Antic, Oct 28: "make a way to apply in the art server, make a new
-- channel called art manager applications" ... "and the same with dev manager"). Rides flag area_managers (634).
--
-- Two fixed channels, made here if the servers exist: #art-manager-applications in Official Yapper Artists
-- (3ad8fe8b, Information category) and #dev-manager-applications in Yapper Developers (a215c9b9, Start here). Both
-- read only: the app shows an Apply card where the composer would be (components/AreaApplyCard.tsx, matched by the
-- fixed id, or by server + name if Antic makes the channel by hand instead).
-- Applications work like staff applications (589): table with no grants, everything through RPCs. Who may apply
-- (area_apply_block): signed in, not an admin, not already that kind of manager, not banned or timed out, account 14+
-- days old, one waiting per area, 30 days after a decline, a day after taking one back. Form: why (30-1000), links to
-- their work (portfolio / their bots, up to 500), experience (up to 1000), agree to the rules.
-- Review: Mod Center, "Manager applications" (admins; Management, head mods and the area's own managers read the
-- list too). Only admins accept (admin_set_area_manager is admin only) or decline; declines are logged
-- (area_app_declined). The applicant hears live (bc_notice 'area_application') and on the next start
-- (my_area_decision), like 589. Re-runnable.

set lock_timeout = '3s';

create table if not exists public.area_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  area text not null check (area in ('art', 'dev')),
  why text not null,
  links text not null default '',
  experience text not null default '',
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  note text not null default '',
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  seen_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.area_applications enable row level security;
revoke all on public.area_applications from anon, authenticated;
create index if not exists area_applications_user_idx on public.area_applications (user_id, created_at desc);
create index if not exists area_applications_pending_idx on public.area_applications (area, created_at) where status = 'pending';
create index if not exists area_applications_decided_by_idx on public.area_applications (decided_by) where decided_by is not null;
-- Second guard under the advisory lock: one waiting application per person per area.
create unique index if not exists area_applications_one_pending on public.area_applications (user_id, area) where status = 'pending';

create or replace function public.art_apply_channel_id()
returns uuid language sql immutable as $$ select '6240a7c1-9b1e-4a8e-8d3f-0c2b5a7e1a01'::uuid $$;
create or replace function public.dev_apply_channel_id()
returns uuid language sql immutable as $$ select '6240a7c1-9b1e-4a8e-8d3f-0c2b5a7e1a02'::uuid $$;

-- The two channels, read only, under the servers' information category, after the last channel. Skipped where the
-- server isn't there (test databases) or the channel already is. yapper.bot so the creation triggers treat it as ours.
do $$
declare
  art constant uuid := '00000000-0000-4000-8000-00000000b004';
  dev constant uuid := '00000000-0000-4000-8000-00000000b005';
  antic constant uuid := '00000000-0000-4000-8000-00000000a001';
  cat uuid; pos int;
begin
  if to_regclass('public.servers') is null or to_regclass('public.channel_categories') is null then return; end if;
  perform set_config('yapper.bot', '1', true);
  if exists (select 1 from public.servers where id = art) and not exists (select 1 from public.channels where id = public.art_apply_channel_id()) then
    select id into cat from public.channel_categories where server_id = art and name = 'Information' limit 1;
    select coalesce(max(position), -1) + 1 into pos from public.channels where server_id = art;
    insert into public.channels (id, kind, name, server_id, created_by, position, read_only, category_id)
    values (public.art_apply_channel_id(), 'text', 'art-manager-applications', art, antic, pos, true, cat);
  end if;
  cat := null; pos := null;
  if exists (select 1 from public.servers where id = dev) and not exists (select 1 from public.channels where id = public.dev_apply_channel_id()) then
    select id into cat from public.channel_categories where server_id = dev and name = 'Start here' limit 1;
    select coalesce(max(position), -1) + 1 into pos from public.channels where server_id = dev;
    insert into public.channels (id, kind, name, server_id, created_by, position, read_only, category_id)
    values (public.dev_apply_channel_id(), 'text', 'dev-manager-applications', dev, antic, pos, true, cat);
  end if;
  perform set_config('yapper.bot', '', true);
end $$;

-- Why I can't apply for this area right now, or null.
create or replace function public.area_apply_block(p_area text)
returns text language plpgsql stable security definer set search_path = public as $$
declare made timestamptz; last public.area_applications;
begin
  if auth.uid() is null then return 'Not signed in'; end if;
  if p_area not in ('art', 'dev') then return 'Unknown role'; end if;
  if exists (select 1 from public.site_admins where user_id = auth.uid()) then return 'You''re an admin already'; end if;
  if exists (select 1 from public.site_area_managers where user_id = auth.uid() and area = p_area) then
    return 'You''re ' || case when p_area = 'art' then 'an Art Manager' else 'a Dev Manager' end || ' already';
  end if;
  if public.is_site_banned(auth.uid()) then return 'That account is banned'; end if;
  if coalesce((select muted_until > now() from public.profiles where id = auth.uid()), false) then return 'You''re timed out right now'; end if;
  select created_at into made from public.profiles where id = auth.uid();
  if made is null or made > now() - interval '14 days' then return 'Your account needs to be at least 14 days old to apply'; end if;
  select * into last from public.area_applications where user_id = auth.uid() and area = p_area order by created_at desc limit 1;
  if last.status = 'pending' then return 'You already have an application waiting'; end if;
  if last.status = 'declined' and last.decided_at > now() - interval '30 days' then
    return 'You can apply again ' || to_char(last.decided_at + interval '30 days', 'Mon FMDD');
  end if;
  if last.status = 'withdrawn' and last.decided_at > now() - interval '1 day' then return 'You took one back recently. Try again tomorrow'; end if;
  return null;
end $$;
revoke execute on function public.area_apply_block(text) from public, anon;
grant execute on function public.area_apply_block(text) to authenticated;

-- What the card needs: is the feature on for me, can I apply (and why not), my latest application for this area.
create or replace function public.my_area_application(p_area text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.area_applications;
begin
  if auth.uid() is null or p_area not in ('art', 'dev') or not public.feature_on('area_managers', null) then return jsonb_build_object('on', false); end if;
  select * into a from public.area_applications where user_id = auth.uid() and area = p_area order by created_at desc limit 1;
  return jsonb_build_object(
    'on', true,
    'block', public.area_apply_block(p_area),
    'app', case when a.id is null then null else jsonb_build_object(
      'id', a.id, 'status', a.status, 'why', a.why, 'links', a.links, 'experience', a.experience, 'note', a.note,
      'created_at', a.created_at, 'decided_at', a.decided_at) end);
end $$;
revoke execute on function public.my_area_application(text) from public, anon;
grant execute on function public.my_area_application(text) to authenticated;

create or replace function public.apply_area_manager(p_area text, p_why text, p_links text default '', p_experience text default '', p_agree boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare b text; w text := btrim(coalesce(p_why, '')); l text := btrim(coalesce(p_links, '')); ex text := btrim(coalesce(p_experience, '')); rid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_area not in ('art', 'dev') then raise exception 'Unknown role'; end if;
  if not public.feature_on('area_managers', null) then raise exception 'Applications aren''t open yet'; end if;
  perform pg_advisory_xact_lock(hashtextextended('area_apply:' || auth.uid()::text, 0));
  b := public.area_apply_block(p_area);
  if b is not null then raise exception '%', b; end if;
  if not coalesce(p_agree, false) then raise exception 'You need to agree to the rules'; end if;
  if length(w) < 30 then raise exception 'Tell us a bit more about why (30 characters at least)'; end if;
  if length(w) > 1000 or length(ex) > 1000 then raise exception 'Keep each answer under 1000 characters'; end if;
  if length(l) > 500 then raise exception 'Keep the links under 500 characters'; end if;
  update public.area_applications set seen_at = now() where user_id = auth.uid() and area = p_area and seen_at is null;
  insert into public.area_applications (user_id, area, why, links, experience) values (auth.uid(), p_area, w, l, ex) returning id into rid;
  return rid;
end $$;
revoke execute on function public.apply_area_manager(text, text, text, text, boolean) from public, anon;
grant execute on function public.apply_area_manager(text, text, text, text, boolean) to authenticated;

create or replace function public.withdraw_area_application(p_area text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update public.area_applications set status = 'withdrawn', decided_at = now(), seen_at = now()
    where user_id = auth.uid() and area = p_area and status = 'pending';
end $$;
revoke execute on function public.withdraw_area_application(text) from public, anon;
grant execute on function public.withdraw_area_application(text) to authenticated;

-- Who reads the list: staff (admins and mods, Management and head mods included), and an area's own managers for
-- their area. `work` is what helps judge: approved decorations for art, bots (verified) for dev.
create or replace function public.area_applications_list()
returns table (id uuid, area text, user_id uuid, why text, links text, experience text, created_at timestamptz,
               joined_at timestamptz, servers int, past_declines int, work int, work_ok int)
language plpgsql stable security definer set search_path = public as $$
declare areas text[] := '{}';
begin
  if public.is_staff() then areas := array['art', 'dev'];
  else
    if public.is_art_manager() then areas := array_append(areas, 'art'); end if;
    if public.is_dev_manager() then areas := array_append(areas, 'dev'); end if;
  end if;
  if areas = '{}' then raise exception 'Staff only'; end if;
  return query select a.id, a.area, a.user_id, a.why, a.links, a.experience, a.created_at, p.created_at,
      (select count(*)::int from public.server_members m where m.user_id = a.user_id),
      (select count(*)::int from public.area_applications d where d.user_id = a.user_id and d.area = a.area and d.status = 'declined'),
      case when a.area = 'art' then (select count(*)::int from public.community_decos d where d.artist_id = a.user_id and d.status in ('pending', 'approved'))
           else (select count(*)::int from public.bots b where b.owner_id = a.user_id) end,
      case when a.area = 'art' then (select count(*)::int from public.community_decos d where d.artist_id = a.user_id and d.status = 'approved')
           else (select count(*)::int from public.bots b where b.owner_id = a.user_id and b.verified_at is not null) end
    from public.area_applications a join public.profiles p on p.id = a.user_id
    where a.status = 'pending' and a.area = any(areas) order by a.created_at limit 200;
end $$;
revoke execute on function public.area_applications_list() from public, anon;
grant execute on function public.area_applications_list() to authenticated;

-- Accept (makes them the manager through admin_set_area_manager, admins only) or decline (logged, note to them).
create or replace function public.decide_area_application(rid uuid, p_accept boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare a public.area_applications; n text := left(btrim(coalesce(p_note, '')), 300);
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if p_accept is null then raise exception 'Accept or decline'; end if;
  select * into a from public.area_applications where id = rid for update;
  if a.id is null then raise exception 'That application is gone'; end if;
  if a.status <> 'pending' then raise exception 'Someone already decided that one'; end if;
  if a.user_id = auth.uid() then raise exception 'You can''t decide your own application'; end if;
  if p_accept then
    if coalesce((select muted_until > now() from public.profiles where id = a.user_id), false) then raise exception 'They''re timed out right now'; end if;
    perform public.admin_set_area_manager(a.user_id, a.area, true, 'Application');
  else
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'area_app_declined', a.user_id, left(a.area || ': ' || n, 300));
  end if;
  update public.area_applications
    set status = case when p_accept then 'accepted' else 'declined' end, note = n, decided_by = auth.uid(), decided_at = now(), seen_at = null
    where id = rid;
  perform public.bc_notice('user:' || a.user_id, 'area_application', jsonb_build_object(
    'id', rid, 'area', a.area, 'status', case when p_accept then 'accepted' else 'declined' end, 'note', n));
end $$;
revoke execute on function public.decide_area_application(uuid, boolean, text) from public, anon;
grant execute on function public.decide_area_application(uuid, boolean, text) to authenticated;

-- The decision I haven't seen yet (app start, only where the flag is on for me).
create or replace function public.my_area_decision()
returns table (id uuid, area text, status text, note text, decided_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  return query select a.id, a.area, a.status, a.note, a.decided_at from public.area_applications a
    where a.user_id = auth.uid() and a.status in ('accepted', 'declined') and a.seen_at is null
    order by a.decided_at desc limit 1;
end $$;
revoke execute on function public.my_area_decision() from public, anon;
grant execute on function public.my_area_decision() to authenticated;

create or replace function public.ack_area_decision(rid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update public.area_applications set seen_at = now() where id = rid and user_id = auth.uid() and seen_at is null;
end $$;
revoke execute on function public.ack_area_decision(uuid) from public, anon;
grant execute on function public.ack_area_decision(uuid) to authenticated;
