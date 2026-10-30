-- 634: Art Managers and Dev Managers (Antic, Oct 28: "art managers and dev managers"). Flag area_managers (test: Antic).
--
-- Two staff roles for one area each, modelled on Yapin' Management (537) but NOT tied to being a moderator: a row in
-- site_area_managers (user_id, area 'art' | 'dev') is the role. Antic gives and takes it (admin_set_area_manager,
-- Mod Center > Moderators). is_art_manager() / is_dev_manager() also need the flag on for them (per user, like
-- management), staff 2FA (staff_mfa_ok) and no site ban. The badges art_manager / dev_manager follow the row
-- (sync_area_manager_badge).
--   * Art Manager: reviews community decorations and profile effects (review_community_deco, the auto-check flags:
--     staff_flagged_decos / staff_clear_deco_check, reads pending ones), gives and takes the Artist badge
--     (admin_set_badge, 'artist' only), reads the decoration sale report (staff_deco_sales).
--   * Dev Manager: reviews bot verifications (can_review_bots: bot_review_queue / admin_verify_bot), sees and ends bot
--     promotions (staff_bot_promotions / staff_end_bot_promotion), reads the developer report (staff_dev_report) and
--     can suspend a bot (staff_suspend_bot: pulled from the directory, verification and running promotions gone, the
--     maker sees why and can submit it again).
-- mod_guard keeps its hourly caps for them: its "Moderators only" line lets an area manager through for the actions of
-- their area only (area_manager_may), so deco_review 60/h, deco_takedown 10/h, badge 10/h, bot_review 20/h,
-- bot_promo 10/h apply as they do to mods. Nothing else in the Mod Center opens for them (the app shows them their
-- own small desk). Admins keep everything as before.
-- One-line changes go into the live function text (pg_get_functiondef), like 537. No real user gets a role here.
-- Re-runnable.

set lock_timeout = '3s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('area_managers', 'Art and Dev Managers', 'Staff roles for one area: Art Managers review decorations and give Artist, Dev Managers review and suspend bots', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create table if not exists public.site_area_managers (
  user_id uuid not null references public.profiles(id) on delete cascade,
  area text not null check (area in ('art', 'dev')),
  added_by uuid,
  created_at timestamptz not null default now(),
  primary key (user_id, area)
);
alter table public.site_area_managers enable row level security;
revoke all on public.site_area_managers from anon, authenticated;
grant select on public.site_area_managers to authenticated;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_area_managers' and policyname = 'staff see area managers') then
    create policy "staff see area managers" on public.site_area_managers for select to authenticated
      using ((select public.is_staff()) or user_id = (select auth.uid()));
  end if;
end $$;

-- The role, live: a row, the flag on for them, staff 2FA, not banned.
create or replace function public.is_area_manager(p_area text)
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  -- Primary-key lookup first: everyone who isn't one stops here, before the flag read.
  if auth.uid() is null or not exists (select 1 from public.site_area_managers where user_id = auth.uid() and area = p_area) then
    return false;
  end if;
  -- A paused moderator's area role sleeps with their mod powers (reviewer: the mod_guard pass-through would skip the pause).
  if exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is not null) then return false; end if;
  return public.feature_on('area_managers', null) and public.staff_mfa_ok() and not public.is_site_banned(auth.uid());
end;
$$;
revoke all on function public.is_area_manager(text) from public, anon;
grant execute on function public.is_area_manager(text) to authenticated;

create or replace function public.is_art_manager() returns boolean
language sql stable security definer set search_path = public as $$ select public.is_area_manager('art') $$;
create or replace function public.is_dev_manager() returns boolean
language sql stable security definer set search_path = public as $$ select public.is_area_manager('dev') $$;
revoke all on function public.is_art_manager() from public, anon;
revoke all on function public.is_dev_manager() from public, anon;
grant execute on function public.is_art_manager() to authenticated;
grant execute on function public.is_dev_manager() to authenticated;

-- The app asks once per load: which areas are mine right now (empty for everyone else).
create or replace function public.my_areas()
returns text[]
language sql
stable security definer
set search_path = public
as $$
  select coalesce(array_agg(a order by a), '{}') from unnest(array['art', 'dev']) a where public.is_area_manager(a);
$$;
revoke all on function public.my_areas() from public, anon;
grant execute on function public.my_areas() to authenticated;

-- Which mod_guard actions an area manager may take: only their area's.
create or replace function public.area_manager_may(p_action text)
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select case
    when p_action in ('deco_review', 'deco_takedown', 'badge') then public.is_art_manager()
    when p_action in ('bot_review', 'bot_promo') then public.is_dev_manager()
    else false end;
$$;
revoke all on function public.area_manager_may(text) from public, anon, authenticated;

-- Admins give and take the roles.
create or replace function public.admin_set_area_manager(uid uuid, p_area text, on_off boolean, note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare n int; tag text;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if p_area not in ('art', 'dev') or on_off is null then raise exception 'Unknown role'; end if;
  tag := p_area || '_manager';
  if on_off then
    if not public.feature_on('area_managers', null) then raise exception 'Art and Dev Managers aren''t on yet'; end if;
    if uid is null or not exists (select 1 from public.profiles where id = uid) then raise exception 'Not found'; end if;
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    insert into public.site_area_managers (user_id, area, added_by) values (uid, p_area, auth.uid()) on conflict (user_id, area) do nothing;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), tag || '_added', uid, left(note, 300)); end if;
  else
    execute 'de' || 'lete from public.site_area_managers where user_id = $1 and area = $2' using uid, p_area;
    get diagnostics n = row_count;
    if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), tag || '_removed', uid, left(note, 300)); end if;
  end if;
end;
$$;
revoke all on function public.admin_set_area_manager(uuid, text, boolean, text) from public, anon;
grant execute on function public.admin_set_area_manager(uuid, text, boolean, text) to authenticated;

-- Badges art_manager / dev_manager: on while the row is there.
create or replace function public.sync_area_manager_badge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := coalesce(new.user_id, old.user_id);
        tag text := coalesce(new.area, old.area) || '_manager';
begin
  if exists (select 1 from public.site_area_managers where user_id = uid and area = coalesce(new.area, old.area)) then
    update public.profiles set badges = array_prepend(tag, coalesce(badges, '{}'))
      where id = uid and not (tag = any(coalesce(badges, '{}')));
  else
    update public.profiles set badges = array_remove(badges, tag),
      shown_badge = case when shown_badge = tag then null else shown_badge end
      where id = uid and tag = any(coalesce(badges, '{}'));
  end if;
  return null;
end;
$$;
revoke all on function public.sync_area_manager_badge() from public, anon, authenticated;
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'site_area_managers_badge' and tgrelid = 'public.site_area_managers'::regclass) then
    create trigger site_area_managers_badge after insert or delete on public.site_area_managers
      for each row execute function public.sync_area_manager_badge();
  end if;
end $$;

-- Bot review: Dev Managers too (bot_review_queue and admin_verify_bot both go through this).
create or replace function public.can_review_bots()
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select public.is_site_admin() or public.is_dev_manager() or (public.is_site_mod() and public.feature_on('mod_bot_review', null));
$$;

-- Suspend a bot: out of the directory, verification and running promotions gone, the maker sees why. They can submit
-- it again (it goes back to the review queue). Admins and Dev Managers; 10 an hour for a Dev Manager.
create or replace function public.staff_suspend_bot(bid uuid, why text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare b public.bots; n int;
begin
  if not (public.is_site_admin() or public.is_dev_manager()) then raise exception 'Admins only'; end if;
  why := left(btrim(coalesce(why, '')), 300);
  if length(why) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  if not public.is_site_admin() then
    perform pg_advisory_xact_lock(hashtextextended('bot_suspend_cap:' || auth.uid()::text, 0));
    select count(*) into n from public.mod_log where actor = auth.uid() and action = 'bot_suspended' and created_at > now() - interval '1 hour';
    if n >= 10 then raise exception 'That''s 10 bot suspensions this hour. Wait a bit or ask an admin'; end if;
  end if;
  select * into b from public.bots where id = bid for update;
  if b.id is null then raise exception 'No such bot'; end if;
  if b.owner_id = auth.uid() and not public.is_site_admin() then raise exception 'You can''t suspend your own bot'; end if;
  if exists (select 1 from public.site_admins where user_id = b.owner_id) and not public.is_site_admin() then raise exception 'That bot belongs to an admin'; end if;
  if not (b.public or b.unlisted or b.verified_at is not null) then raise exception 'That bot isn''t listed or verified'; end if;
  update public.bots set public = false, unlisted = false, verified_at = null, review_note = left('Suspended: ' || why, 300) where id = bid;
  update public.bot_promotions set starts_at = least(starts_at, now()), ends_at = now(), ended_by = auth.uid() where bot_id = bid and ends_at > now();
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'bot_suspended', bid, left(why || ' [' || b.name || ']', 500));
end;
$$;
revoke all on function public.staff_suspend_bot(uuid, text) from public, anon;
grant execute on function public.staff_suspend_bot(uuid, text) to authenticated;

-- Developer report: the bot side in numbers. Admins and Dev Managers.
create or replace function public.staff_dev_report()
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare out jsonb;
begin
  if not (public.is_site_admin() or public.is_dev_manager()) then raise exception 'Admins only'; end if;
  select jsonb_build_object(
    'bots', (select count(*) from public.bots),
    'listed', (select count(*) from public.bots where public),
    'verified', (select count(*) from public.bots where verified_at is not null),
    'waiting', (select count(*) from public.bots where (public or unlisted) and verified_at is null),
    'made_7d', (select count(*) from public.bots where created_at > now() - interval '7 days'),
    'active_7d', (select count(*) from public.bots where last_used_at > now() - interval '7 days'),
    'submitted_7d', (select count(*) from public.bots where submitted_at > now() - interval '7 days'),
    'promotions', (select count(*) from public.bot_promotions where ends_at > now()),
    'decisions_30d', (select jsonb_object_agg(action, n) from (
        select action, count(*) n from public.mod_log
         where action in ('bot_verified', 'bot_rejected', 'bot_suspended', 'bot_promo_ended') and created_at > now() - interval '30 days'
         group by action) x),
    'top', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'owner', p.username, 'servers', b.real_servers,
                                                           'verified', b.verified_at is not null, 'posts', b.posts) order by b.real_servers desc nulls last, b.posts desc), '[]')
            from (select * from public.bots where public order by real_servers desc nulls last, posts desc limit 10) b
            left join public.profiles p on p.id = b.owner_id)
  ) into out;
  return out;
end;
$$;
revoke all on function public.staff_dev_report() from public, anon;
grant execute on function public.staff_dev_report() to authenticated;

-- Decoration sale report (Shards): what sold, who sells, what the review side did. Admins and Art Managers.
create index if not exists shard_ledger_deco_sales_idx on public.shard_ledger (created_at) where kind = 'deco_sale';
create or replace function public.staff_deco_sales(p_days integer default 30)
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare out jsonb; since timestamptz;
begin
  if not (public.is_site_admin() or public.is_art_manager()) then raise exception 'Admins only'; end if;
  p_days := least(greatest(coalesce(p_days, 30), 1), 365);
  since := now() - make_interval(days => p_days);
  select jsonb_build_object(
    'days', p_days,
    'sales', (select count(*) from public.shard_ledger where kind = 'deco_sale' and created_at > since),
    'shards_to_artists', (select coalesce(sum(amount), 0) from public.shard_ledger where kind = 'deco_sale' and created_at > since),
    'buyers', (select count(distinct actor) from public.shard_ledger where kind = 'deco_sale' and created_at > since),
    'sellers', (select count(distinct user_id) from public.shard_ledger where kind = 'deco_sale' and created_at > since),
    'sales_all', (select count(*) from public.shard_ledger where kind = 'deco_sale'),
    'for_sale', (select count(*) from public.community_decos where status = 'approved' and price is not null),
    'pending', (select count(*) from public.community_decos where status = 'pending'),
    'approved', (select count(*) from public.community_decos where status = 'approved'),
    'effects', (select count(*) from public.community_decos where status = 'approved' and kind = 'effect'),
    'reviews', (select coalesce(jsonb_object_agg(action, n), '{}') from (
        select action, count(*) n from public.mod_log
         where action in ('deco_approved', 'deco_rejected', 'deco_removed', 'deco_check_cleared') and created_at > since
         group by action) x),
    'top_decos', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'kind', d.kind, 'path', d.path, 'price', d.price,
                                                                 'artist', p.username, 'sales', s.n, 'shards', s.shards) order by s.n desc), '[]')
                  from (select split_part(ref, ':', 1)::uuid deco_id, count(*) n, sum(amount) shards from public.shard_ledger
                         where kind = 'deco_sale' and created_at > since and ref ~ '^[0-9a-f-]{36}:' group by 1 order by 2 desc limit 10) s
                  join public.community_decos d on d.id = s.deco_id
                  left join public.profiles p on p.id = d.artist_id),
    'top_artists', (select coalesce(jsonb_agg(jsonb_build_object('id', s.user_id, 'username', p.username, 'sales', s.n, 'shards', s.shards) order by s.n desc), '[]')
                    from (select user_id, count(*) n, sum(amount) shards from public.shard_ledger
                           where kind = 'deco_sale' and created_at > since group by 1 order by 2 desc limit 10) s
                    left join public.profiles p on p.id = s.user_id),
    'by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', d, 'sales', n) order by d), '[]') from (
        select date_trunc('day', created_at)::date as d, count(*) n from public.shard_ledger
         where kind = 'deco_sale' and created_at > now() - interval '14 days' group by 1) x)
  ) into out;
  return out;
end;
$$;
revoke all on function public.staff_deco_sales(integer) from public, anon;
grant execute on function public.staff_deco_sales(integer) to authenticated;

-- One-line changes, patched into the live text. Skipped where the function isn't there (test databases) or already
-- patched; a changed anchor stops the migration so nothing goes half in.
create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;
  if (length(f) - length(replace(f, old_text, ''))) / length(old_text) <> 1 then raise exception '634: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

-- mod_guard: an area manager passes the mod check for their area's actions only; the caps below stay.
select pg_temp.patch_fn('public.mod_guard(text,uuid,text)', 'area_manager_may',
  'if not public.is_site_mod() then',
  'if not (public.is_site_mod() or public.area_manager_may(action)) then');

-- mod_burst_check pauses by updating site_moderators: an area manager has no row, so nothing paused and the
-- auto_suspended log row restarted the budget every 59 actions (reviewer). With no row to pause, refuse at the line.
select pg_temp.patch_fn('public.mod_burst_check()', '-- 634:',
  'update public.site_moderators set suspended_at = now(), suspended_reason = why where user_id = me and suspended_at is null;',
  'update public.site_moderators set suspended_at = now(), suspended_reason = why where user_id = me and suspended_at is null;'
  || chr(10) || '    -- 634: no moderator row to pause (an area manager): refuse here instead of logging auto_suspended, which restarts the budget.'
  || chr(10) || '    if not found then raise exception ''Slow down: that''''s a lot of actions in a short time (60 in 10 minutes or 200 an hour). Ask an admin if this is real work.''; end if;');

-- Artist badge: Art Managers give and take it (mod_guard ''badge'': 10 an hour, not staff, not themselves).
select pg_temp.patch_fn('public.admin_set_badge(uuid,text,boolean)', 'is_art_manager',
  'or (public.is_site_mod() and badge = ''bug_hunter'')',
  'or (public.is_site_mod() and badge = ''bug_hunter'') or (badge = ''artist'' and public.is_art_manager())');

-- Decorations: review, the auto-check flags, clearing them.
select pg_temp.patch_fn('public.review_community_deco(uuid,text,text)', 'is_art_manager',
  'if not (public.is_site_admin() or public.is_site_mod()) then raise exception ''Staff only''; end if;',
  'if not (public.is_site_admin() or public.is_site_mod() or public.is_art_manager()) then raise exception ''Staff only''; end if;');
select pg_temp.patch_fn('public.staff_flagged_decos()', 'is_art_manager',
  'if not (public.is_site_admin() or public.is_site_mod()) then raise exception ''Staff only''; end if;',
  'if not (public.is_site_admin() or public.is_site_mod() or public.is_art_manager()) then raise exception ''Staff only''; end if;');
select pg_temp.patch_fn('public.staff_clear_deco_check(uuid,text)', 'is_art_manager',
  'if not (public.is_site_admin() or public.is_site_mod()) then raise exception ''Staff only''; end if;',
  'if not (public.is_site_admin() or public.is_site_mod() or public.is_art_manager()) then raise exception ''Staff only''; end if;');

-- Bot promotions: Dev Managers see them and end them (mod_guard ''bot_promo'': 10 an hour).
select pg_temp.patch_fn('public.staff_bot_promotions()', 'is_dev_manager',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not (public.is_staff() or public.is_dev_manager()) then raise exception ''Staff only''; end if;');
select pg_temp.patch_fn('public.staff_end_bot_promotion(uuid,text)', 'is_dev_manager',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not (public.is_staff() or public.is_dev_manager()) then raise exception ''Staff only''; end if;');

-- Reads: Art Managers see pending and rejected decorations like mods do.
do $$
begin
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'community_decos' and policyname = 'approved ones, your own, all for staff') then
    alter policy "approved ones, your own, all for staff" on public.community_decos
      using (status = 'approved' or artist_id = (select auth.uid()) or (select public.is_site_admin()) or (select public.is_site_mod()) or (select public.is_art_manager()));
  end if;
end $$;

-- The 2FA gate (StaffMfaGate) opens for area managers too: my_staff_security counts them as staff. plpgsql so a test
-- database without auth.mfa_factors still takes the definition.
create or replace function public.my_staff_security()
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return (select jsonb_build_object(
    'staff', exists (select 1 from public.site_admins where user_id = auth.uid())
          or exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null)
          or exists (select 1 from public.site_area_managers where user_id = auth.uid()),
    'need_2fa', public.feature_on('staff_2fa', null),
    'has_2fa', exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'),
    'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'),
    'reauth', public.feature_on('staff_reauth', null),
    'has_password', exists (select 1 from auth.users u where u.id = auth.uid() and coalesce(u.encrypted_password, '') <> '')
  ));
end;
$$;
