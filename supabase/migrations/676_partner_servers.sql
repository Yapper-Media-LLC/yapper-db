-- 676: Yapin' Partner servers (flag partner_servers, test: Antic + the HQ test server). Like Discord's Partner Program.
-- Owners see a checklist in Server Settings > Yapin' Partner (partner_eligibility) and apply once every check passes
-- (partner_apply). Admins and Management review in the Mod Center (partner_queue, partner_review) and can take it back
-- (partner_revoke); every decision lands in mod_log and reaches the owner live (bc_notice) and on their next start
-- (my_partner_decisions, read only where the flag is on). Approved servers get servers.partner_since (the badge next to
-- the name; it rides the existing bootstrap / loadServers / servers_bc paths) and the owner gets the 'partner' user badge.
-- partner_recheck (daily cron) watches partners: a partner below the requirements for 30 days in a row is flagged for
-- staff in the same queue. Nothing is revoked automatically.
-- Requirements (partner_check): Supercharge level 2 or higher (Antic), 1000+ members, a rules channel or onboarding on, 2+ people besides
-- the owner who moderated (server_audit_log) in the last 30 days, verification level Medium or higher, the server and the
-- owner's account 8+ weeks old, and a clean record (no open server reports, not shut down / hidden / warned by staff in
-- 90 days, name ok, owner not site-banned). There is no NSFW marker on servers yet: any open server report (NSFW ones
-- included) blocks until staff close it, and staff are the last check anyway.
-- No data is changed here: no badges are given, no servers are marked. Re-runnable.
set lock_timeout = '4s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('partner_servers', 'Yapin'' Partner servers', 'Owners of big, well-run servers apply to be a Yapin'' Partner (Server Settings). Staff review in the Mod Center. Partners get a badge next to the server name and the owner gets the Partner badge.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- Null = not a partner. Clients have no UPDATE grant on servers, so only the definer functions below set it.
-- A nullable column without a default is a catalog-only change.
alter table public.servers add column if not exists partner_since timestamptz;

-- ---------- tables ----------
create table if not exists public.partner_applications (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers (id) on delete cascade,
  -- The owner when they applied; moves with the server (partner_owner_moved) once approved, as it holds the badge.
  owner_id uuid not null references public.profiles (id) on delete cascade,
  about text not null,
  links text[] not null default '{}',
  checks jsonb,                                   -- the checklist as it was when they applied
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'revoked')),
  staff_note text,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  gave_badge boolean not null default false,      -- the owner didn't have 'partner' before, so taking it back is ours to do
  seen_at timestamptz,                            -- the owner dismissed the decision notice
  created_at timestamptz not null default now()
);
create index if not exists partner_applications_server_idx on public.partner_applications (server_id, created_at desc);
create index if not exists partner_applications_owner_idx on public.partner_applications (owner_id, created_at desc);
create index if not exists partner_applications_reviewer_idx on public.partner_applications (reviewed_by) where reviewed_by is not null;
create index if not exists partner_applications_pending_idx on public.partner_applications (created_at) where status = 'pending';
-- One open application per server (two quick clicks, two tabs).
create unique index if not exists partner_applications_one_pending on public.partner_applications (server_id) where status = 'pending';
-- my_partner_decisions on start: only rows still waiting to be seen.
create index if not exists partner_applications_unseen_idx on public.partner_applications (owner_id)
  where seen_at is null and status <> 'pending';

-- Partners that fell below the requirements. below_since = first check that failed in the current run of fails;
-- flagged_at = staff were told (30 days below). Cleared when the server passes again.
create table if not exists public.partner_watch (
  server_id uuid primary key references public.servers (id) on delete cascade,
  below_since timestamptz,
  failing text[] not null default '{}',
  flagged_at timestamptz,
  checked_at timestamptz not null default now()
);
create index if not exists partner_watch_flagged_idx on public.partner_watch (flagged_at) where flagged_at is not null;

-- Everything goes through the functions below.
alter table public.partner_applications enable row level security;
alter table public.partner_watch enable row level security;
revoke all on public.partner_applications from anon, authenticated;
revoke all on public.partner_watch from anon, authenticated;

-- ---------- who reviews ----------
create or replace function public.partner_reviewer()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_manager()
$$;
revoke all on function public.partner_reviewer() from public, anon, authenticated;

-- ---------- the checklist ----------
-- Indexed reads only, for one server: never on app start (the settings page, apply, review and the daily recheck).
create or replace function public.partner_check(sid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s record; lvl int; mods int := 0; lo bigint; rules text; born timestamptz; days int; open_reports int; clean_why text;
  checks jsonb;
begin
  select id, owner_id, created_at, member_count, rules_channel_id, verification_level, shut_down_at, staff_hidden_at,
         staff_warned_at, name_ok
    into s from public.servers where id = sid;
  if s.id is null then return null; end if;

  lvl := coalesce(public.server_level(sid), 0);

  rules := case
    when s.rules_channel_id is not null then 'Rules channel'
    when exists (select 1 from public.server_onboarding o where o.server_id = sid and o.enabled) then 'Onboarding'
  end;

  -- People besides the owner who did real moderation (bans, kicks, timeouts, voice actions on someone else) in the last
  -- 30 days and are still here. The 30 days are an id range (ids follow created_at): the first id in the window comes
  -- from server_audit_log_created_idx, then server_audit_log_server_idx is a pure range scan. Distinct actors first,
  -- then the member and bot checks on that small set.
  select l.id into lo from public.server_audit_log l where l.created_at > now() - interval '30 days' order by l.created_at limit 1;
  select count(*) into mods
  from (select distinct l.actor_id from public.server_audit_log l
         where l.server_id = sid and l.id >= lo and l.created_at > now() - interval '30 days'
           and l.action in ('member_ban', 'member_unban', 'member_kick', 'member_timeout', 'member_timeout_remove',
                            'voice_mute', 'voice_unmute', 'voice_ban', 'voice_unban', 'voice_disconnect', 'voice_move')
           and l.actor_id is not null and l.actor_id <> s.owner_id and l.target_id is distinct from l.actor_id) a
  where exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = a.actor_id)
    and not public.is_bot_user(a.actor_id);

  select created_at into born from public.profiles where id = s.owner_id;
  days := floor(extract(epoch from (now() - greatest(s.created_at, coalesce(born, now())))) / 86400)::int;

  select count(*) into open_reports from public.reports r where r.reported_server_id = sid and r.status = 'open';
  clean_why := case
    when s.shut_down_at is not null then 'Shut down by staff'
    when s.staff_hidden_at is not null then 'Hidden by staff'
    when s.staff_warned_at is not null and s.staff_warned_at > now() - interval '90 days' then 'Staff warning in the last 90 days'
    when not coalesce(s.name_ok, true) then 'Server name needs a change'
    when public.is_site_banned(s.owner_id) then 'Owner is banned'
    when open_reports > 0 then open_reports || ' open report' || case when open_reports = 1 then '' else 's' end
  end;

  checks := jsonb_build_array(
    jsonb_build_object('key', 'level', 'ok', lvl >= 2, 'value', lvl, 'need', 2),
    jsonb_build_object('key', 'members', 'ok', s.member_count >= 1000, 'value', s.member_count, 'need', 1000),
    jsonb_build_object('key', 'rules', 'ok', rules is not null, 'value', rules),
    jsonb_build_object('key', 'mods', 'ok', mods >= 2, 'value', mods, 'need', 2),
    jsonb_build_object('key', 'safety', 'ok', coalesce(s.verification_level, 0) >= 2, 'value', coalesce(s.verification_level, 0), 'need', 2),
    jsonb_build_object('key', 'age', 'ok', days >= 56, 'value', days, 'need', 56),
    jsonb_build_object('key', 'clean', 'ok', clean_why is null, 'value', clean_why)
  );
  return jsonb_build_object('ok', not exists (select 1 from jsonb_array_elements(checks) c where not (c->>'ok')::boolean),
                            'checks', checks);
end $$;
revoke all on function public.partner_check(uuid) from public, anon, authenticated;

-- ---------- badge upkeep ----------
-- Give 'partner' to uid (returns true when they didn't have it).
create or replace function public.partner_badge_give(uid uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare had boolean;
begin
  perform 1 from public.profiles where id = uid for update;
  select coalesce('partner' = any (badges), false) into had from public.profiles where id = uid;
  if had then return false; end if;
  update public.profiles set badges = array(select distinct unnest(coalesce(badges, '{}'::text[]) || 'partner'::text)) where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'badge_given', uid, 'partner (Partner server)');
  begin perform public.rt_profile_changed(array[uid]); exception when others then raise warning 'rt_profile_changed: %', sqlerrm; end;
  return true;
end $$;
revoke all on function public.partner_badge_give(uuid) from public, anon, authenticated;

-- Take 'partner' back from uid, but only when this program gave it (gave_badge) and they own no other partner server.
-- A badge staff handed out by hand (admin_set_badge) or the Elite Creator one is left alone.
-- skip_server: a partner server being deleted (its row still exists in the before-delete trigger).
create or replace function public.partner_badge_take(uid uuid, app_id uuid, skip_server uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce((select gave_badge from public.partner_applications where id = app_id), false) then return; end if;
  update public.partner_applications set gave_badge = false where id = app_id;
  -- Another partner server of theirs still holds it: hand the "ours" mark to that one.
  if exists (select 1 from public.servers where owner_id = uid and partner_since is not null and id is distinct from skip_server) then
    update public.partner_applications a set gave_badge = true
     where a.id = (select a2.id from public.partner_applications a2 join public.servers s on s.id = a2.server_id
                    where a2.owner_id = uid and s.owner_id = uid and a2.status = 'approved' and s.partner_since is not null
                      and s.id is distinct from skip_server
                    order by a2.reviewed_at desc limit 1);
    return;
  end if;
  if exists (select 1 from public.profiles where id = uid and badges && array['creator_3']) then return; end if;
  -- Staff also gave it by hand since (admin_set_badge logs reason 'partner'; mod_log is indexed on (target_id, created_at)).
  if (select l.action from public.mod_log l where l.target_id = uid and l.reason = 'partner' and l.action in ('badge_given', 'badge_removed')
       order by l.created_at desc limit 1) = 'badge_given' then return; end if;
  perform 1 from public.profiles where id = uid for update;
  update public.profiles set badges = array_remove(badges, 'partner'),
    shown_badge = case when shown_badge = 'partner' then null else shown_badge end
   where id = uid and 'partner' = any (badges);
  if found then
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'badge_removed', uid, 'partner (Partner server)');
    begin perform public.rt_profile_changed(array[uid]); exception when others then raise warning 'rt_profile_changed: %', sqlerrm; end;
  end if;
end $$;
revoke all on function public.partner_badge_take(uuid, uuid, uuid) from public, anon, authenticated;

-- A partner server changed owners: the badge moves with it.
create or replace function public.partner_owner_moved()
returns trigger language plpgsql security definer set search_path = public as $$
declare app uuid; gave boolean;
begin
  select id into app from public.partner_applications
   where server_id = new.id and status = 'approved' order by reviewed_at desc limit 1;
  if app is null then return null; end if;
  perform public.partner_badge_take(old.owner_id, app);
  gave := public.partner_badge_give(new.owner_id);
  update public.partner_applications set owner_id = new.owner_id, gave_badge = gave where id = app;
  return null;
end $$;
revoke all on function public.partner_owner_moved() from public, anon, authenticated;
create or replace trigger servers_partner_owner after update of owner_id on public.servers
  for each row when (old.owner_id is distinct from new.owner_id and new.partner_since is not null)
  execute function public.partner_owner_moved();

-- A partner server is deleted: take the badge back first (the cascade takes the application and its gave_badge with it).
create or replace function public.partner_server_gone()
returns trigger language plpgsql security definer set search_path = public as $$
declare app uuid;
begin
  select id into app from public.partner_applications
   where server_id = old.id and status = 'approved' order by reviewed_at desc limit 1;
  if app is not null then perform public.partner_badge_take(old.owner_id, app, old.id); end if;
  return old;
end $$;
revoke all on function public.partner_server_gone() from public, anon, authenticated;
create or replace trigger servers_partner_gone before delete on public.servers
  for each row when (old.partner_since is not null)
  execute function public.partner_server_gone();

-- ---------- owner: the checklist page ----------
create or replace function public.partner_eligibility(sid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); own uuid; since timestamptz; app jsonb; wait_until timestamptz;
begin
  if not public.feature_on('partner_servers', sid) then raise exception 'Not available yet'; end if;
  select owner_id, partner_since into own, since from public.servers where id = sid;
  if own is null then raise exception 'Server not found'; end if;
  if own is distinct from uid and not public.partner_reviewer() then raise exception 'Only the owner can do that'; end if;
  select jsonb_build_object('id', a.id, 'status', a.status, 'staff_note', a.staff_note, 'about', a.about, 'links', a.links,
                            'created_at', a.created_at, 'reviewed_at', a.reviewed_at)
    into app from public.partner_applications a where a.server_id = sid order by a.created_at desc limit 1;
  if app->>'status' in ('denied', 'revoked') then
    wait_until := (app->>'reviewed_at')::timestamptz + interval '30 days';
    if wait_until < now() then wait_until := null; end if;
  end if;
  return public.partner_check(sid) || jsonb_build_object('partner_since', since, 'application', app, 'wait_until', wait_until);
end $$;
revoke all on function public.partner_eligibility(uuid) from public, anon;
grant execute on function public.partner_eligibility(uuid) to authenticated;

create or replace function public.partner_apply(sid uuid, p_about text, p_links text[] default '{}')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); own uuid; since timestamptz; chk jsonb; a text; l text[]; last record; rid uuid;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('partner_servers', sid) then raise exception 'Not available yet'; end if;
  select owner_id, partner_since into own, since from public.servers where id = sid for update;
  if own is null then raise exception 'Server not found'; end if;
  if own <> uid then raise exception 'Only the owner can do that'; end if;
  if since is not null then raise exception 'This server is already a partner'; end if;
  if exists (select 1 from public.partner_applications where server_id = sid and status = 'pending') then
    raise exception 'You already applied. Staff will take a look.';
  end if;
  select status, reviewed_at into last from public.partner_applications
   where server_id = sid and status in ('denied', 'revoked') order by reviewed_at desc limit 1;
  if last.reviewed_at is not null and last.reviewed_at > now() - interval '30 days' then
    raise exception 'You can apply again 30 days after the last decision';
  end if;
  a := btrim(coalesce(p_about, ''));
  if length(a) < 20 then raise exception 'Tell us a bit more about your server'; end if;
  if length(a) > 1000 then raise exception 'Keep it under 1000 characters'; end if;
  select coalesce(array_agg(x), '{}') into l
    from (select btrim(x) x from unnest(coalesce(p_links, '{}')) x) t where x <> '';
  if cardinality(l) > 5 then raise exception 'Up to 5 links'; end if;
  if exists (select 1 from unnest(l) x where x !~* '^https?://\S+$' or length(x) > 200) then
    raise exception 'Links need to start with https://';
  end if;
  chk := public.partner_check(sid);
  if not (chk->>'ok')::boolean then raise exception 'Your server doesn''t meet every requirement yet'; end if;
  insert into public.partner_applications (server_id, owner_id, about, links, checks)
  values (sid, uid, a, l, chk->'checks')
  returning id into rid;
  return rid;
end $$;
revoke all on function public.partner_apply(uuid, text, text[]) from public, anon;
grant execute on function public.partner_apply(uuid, text, text[]) to authenticated;

-- ---------- owner: decision notices ----------
create or replace function public.my_partner_decisions()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'server_id', a.server_id, 'name', s.name, 'status', a.status,
                                               'note', a.staff_note) order by a.reviewed_at desc), '[]'::jsonb)
  from public.partner_applications a join public.servers s on s.id = a.server_id
  where a.owner_id = auth.uid() and a.seen_at is null and a.status <> 'pending'
$$;
revoke all on function public.my_partner_decisions() from public, anon;
grant execute on function public.my_partner_decisions() to authenticated;

create or replace function public.ack_partner_decision(app_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.partner_applications set seen_at = now()
   where id = app_id and owner_id = auth.uid() and seen_at is null and status <> 'pending'
$$;
revoke all on function public.ack_partner_decision(uuid) from public, anon;
grant execute on function public.ack_partner_decision(uuid) to authenticated;

-- ---------- public: which of these servers are partners (Discover, promoted slots) ----------
create or replace function public.partner_ids(ids uuid[])
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(id), '{}') from public.servers
   where id = any ((coalesce(ids, '{}'))[1:100]) and partner_since is not null
$$;
revoke all on function public.partner_ids(uuid[]) from public;
grant execute on function public.partner_ids(uuid[]) to anon, authenticated;

-- ---------- staff: the queue ----------
create or replace function public.partner_queue()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare apps jsonb; flagged jsonb;
begin
  if not public.partner_reviewer() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('partner_servers') then raise exception 'Not available yet'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'server_id', a.server_id, 'name', s.name, 'icon_path', s.icon_path, 'members', s.member_count,
           'owner_id', a.owner_id, 'owner', p.username, 'about', a.about, 'links', a.links, 'created_at', a.created_at,
           'owner_changed', s.owner_id <> a.owner_id, 'now', public.partner_check(a.server_id)) order by a.created_at), '[]'::jsonb)
    into apps
    from (select * from public.partner_applications where status = 'pending' order by created_at limit 50) a
    join public.servers s on s.id = a.server_id
    left join public.profiles p on p.id = a.owner_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'server_id', w.server_id, 'name', s.name, 'icon_path', s.icon_path, 'members', s.member_count,
           'below_since', w.below_since, 'failing', w.failing, 'flagged_at', w.flagged_at) order by w.flagged_at), '[]'::jsonb)
    into flagged
    from public.partner_watch w join public.servers s on s.id = w.server_id
   where w.flagged_at is not null and s.partner_since is not null;
  return jsonb_build_object('apps', apps, 'flagged', flagged);
end $$;
revoke all on function public.partner_queue() from public, anon;
grant execute on function public.partner_queue() to authenticated;

create or replace function public.partner_review(app_id uuid, approve boolean, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); a record; own uuid; nm text; n text := left(btrim(coalesce(p_note, '')), 500); gave boolean;
begin
  if not public.partner_reviewer() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('partner_servers') then raise exception 'Not available yet'; end if;
  select * into a from public.partner_applications where id = app_id for update;
  if a.id is null then raise exception 'Application not found'; end if;
  if a.status <> 'pending' then raise exception 'Someone already decided on this one'; end if;
  select owner_id, name into own, nm from public.servers where id = a.server_id for update;
  if own = uid or a.owner_id = uid then raise exception 'You can''t review your own server'; end if;
  if approve then
    if own <> a.owner_id then raise exception 'The server changed owners. Deny this one, they can apply again.'; end if;
    if not (public.partner_check(a.server_id)->>'ok')::boolean then
      raise exception 'It doesn''t meet every requirement right now';
    end if;
    update public.servers set partner_since = now() where id = a.server_id;
    update public.partner_watch set below_since = null, failing = '{}', flagged_at = null, checked_at = now() where server_id = a.server_id;
    gave := public.partner_badge_give(own);
    update public.partner_applications set status = 'approved', staff_note = nullif(n, ''), reviewed_by = uid, reviewed_at = now(),
      gave_badge = gave, seen_at = null where id = app_id;
  else
    if length(n) < 3 then raise exception 'Add a short reason, they see it'; end if;
    update public.partner_applications set status = 'denied', staff_note = n, reviewed_by = uid, reviewed_at = now(), seen_at = null
     where id = app_id;
  end if;
  insert into public.mod_log (actor, action, target_id, reason)
  values (uid, case when approve then 'partner_approved' else 'partner_denied' end, a.owner_id,
          left(nm || case when n <> '' then ': ' || n else '' end, 500));
  perform public.bc_notice('user:' || a.owner_id, 'partner_application',
    jsonb_build_object('id', app_id, 'server_id', a.server_id, 'name', nm, 'status', case when approve then 'approved' else 'denied' end));
end $$;
revoke all on function public.partner_review(uuid, boolean, text) from public, anon;
grant execute on function public.partner_review(uuid, boolean, text) to authenticated;

create or replace function public.partner_revoke(sid uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); own uuid; nm text; since timestamptz; app uuid; n text := left(btrim(coalesce(p_note, '')), 500);
begin
  if not public.partner_reviewer() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('partner_servers') then raise exception 'Not available yet'; end if;
  if length(n) < 3 then raise exception 'Add a short reason, they see it'; end if;
  select owner_id, name, partner_since into own, nm, since from public.servers where id = sid for update;
  if own is null then raise exception 'Server not found'; end if;
  if since is null then raise exception 'This server isn''t a partner'; end if;
  if own = uid then raise exception 'You can''t review your own server'; end if;
  update public.servers set partner_since = null where id = sid;
  update public.partner_watch set below_since = null, failing = '{}', flagged_at = null, checked_at = now() where server_id = sid;
  select id into app from public.partner_applications where server_id = sid and status = 'approved' order by reviewed_at desc limit 1;
  if app is not null then
    perform public.partner_badge_take(own, app);
    update public.partner_applications set status = 'revoked', staff_note = n, reviewed_by = uid, reviewed_at = now(), seen_at = null
     where id = app;
  end if;
  insert into public.mod_log (actor, action, target_id, reason) values (uid, 'partner_revoked', own, left(nm || ': ' || n, 500));
  perform public.bc_notice('user:' || own, 'partner_application',
    jsonb_build_object('id', app, 'server_id', sid, 'name', nm, 'status', 'revoked'));
end $$;
revoke all on function public.partner_revoke(uuid, text) from public, anon;
grant execute on function public.partner_revoke(uuid, text) to authenticated;

-- Staff saw a flagged partner and kept it: start the 30 days over.
create or replace function public.partner_keep(sid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.partner_reviewer() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('partner_servers') then raise exception 'Not available yet'; end if;
  update public.partner_watch set below_since = now(), flagged_at = null where server_id = sid and flagged_at is not null;
  if found then
    insert into public.mod_log (actor, action, target_id, reason)
    select auth.uid(), 'partner_kept', owner_id, left(name, 500) from public.servers where id = sid;
  end if;
end $$;
revoke all on function public.partner_keep(uuid) from public, anon;
grant execute on function public.partner_keep(uuid) to authenticated;

-- ---------- daily recheck of partners (cron) ----------
-- Only partner servers (a handful), each one partner_check. Never revokes: it flags for staff after 30 days below.
create or replace function public.partner_recheck()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare r record; chk jsonb; bad text[]; n int := 0;
begin
  for r in select id from public.servers where partner_since is not null loop
    chk := public.partner_check(r.id);
    if chk is null then continue; end if;
    if (chk->>'ok')::boolean then
      update public.partner_watch set below_since = null, failing = '{}', flagged_at = null, checked_at = now() where server_id = r.id;
    else
      select coalesce(array_agg(c->>'key'), '{}') into bad from jsonb_array_elements(chk->'checks') c where not (c->>'ok')::boolean;
      insert into public.partner_watch (server_id, below_since, failing, checked_at) values (r.id, now(), bad, now())
      on conflict (server_id) do update set below_since = coalesce(partner_watch.below_since, now()), failing = excluded.failing,
        checked_at = now();
      update public.partner_watch set flagged_at = now()
       where server_id = r.id and flagged_at is null and below_since <= now() - interval '30 days';
      if found then n := n + 1; end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.partner_recheck() from public, anon, authenticated;
do $$ begin
  -- (no cron schema in the local test database)
  if to_regnamespace('cron') is not null then
    if not exists (select 1 from cron.job where jobname = 'partner-recheck') then
      perform cron.schedule('partner-recheck', '17 5 * * *', 'select public.partner_recheck()');
    end if;
  end if;
end $$;

-- ---------- invite card: + partner ----------
-- Same as 628 plus 'partner'.
create or replace function public.invite_card(invite_code text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'server_id', s.id, 'name', s.name, 'icon_path', s.icon_path,
    'banner_path', s.banner_path, 'banner_x', s.banner_x, 'banner_y', s.banner_y, 'banner_zoom', s.banner_zoom,
    'created_at', s.created_at,
    'member_count', (select count(*) from public.server_members m where m.server_id = s.id),
    'online_count', (select count(*) from public.server_members m join public.presence p on p.user_id = m.user_id
                     where m.server_id = s.id and p.last_seen > now() - public.presence_ttl()),
    'already_member', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid()),
    'partner', s.partner_since is not null
  )
  from public.invites i join public.servers s on s.id = i.server_id
  where lower(i.code) = lower(invite_code);
$function$;
revoke all on function public.invite_card(text) from public;
grant execute on function public.invite_card(text) to anon, authenticated, service_role;
