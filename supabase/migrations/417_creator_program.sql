-- 417: Yapper Creator Program (flag creator_program, test). Applied live Oct 23 10:05 UTC under the name 410_creator_program,
-- renumbered to 417 when main had taken 410 (410_verified_display_name_free).
--   * Joining: verified creators apply from Settings (follower count, a link to something they made about Yapper, a
--     note). An admin reviews in Mod Center, Creators. Approval gives a creator badge tier (creator_1/2/3, same rules
--     as admin_set_badge: one tier at a time, the shown badge follows) and starter Plus (tier 1: 3 months, tiers 2
--     and 3: 12 months) on top of any Plus they already have. Rejections carry a note and start a 30 day wait.
--   * Content: members then send in each video or post they make about Yapper (creator_content). Every approved piece
--     adds a month of Plus. Up to 3 waiting at a time, a link only once per person.
--   * Everything is logged (creator_approved / creator_rejected / creator_revoked, content_approved / content_rejected,
--     badge_given, plus_gift) so plus_until always has a mod_log row behind it (049 treats one without as suspicious).
--   * revoke_creator: badge off, out of the program; Plus already given stays until it runs out.
-- Re-runnable. Locks on profiles wait at most 3 s.
set lock_timeout = '3s';

create table if not exists public.creator_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  followers int not null check (followers between 0 and 1000000000),
  content_link text not null check (content_link ~* '^https?://' and char_length(content_link) <= 300),
  note text not null default '' check (char_length(note) <= 1000),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  tier smallint check (tier between 1 and 3),
  plus_months int,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  review_note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists creator_applications_status_idx on public.creator_applications (status, created_at);
create index if not exists creator_applications_user_idx on public.creator_applications (user_id, created_at desc);
create index if not exists creator_applications_reviewer_idx on public.creator_applications (reviewed_by);
alter table public.creator_applications enable row level security;

create table if not exists public.creator_content (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  link text not null check (link ~* '^https?://' and char_length(link) <= 300),
  note text not null default '' check (char_length(note) <= 500),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reward_months int not null default 1,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  review_note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists creator_content_status_idx on public.creator_content (status, created_at);
create index if not exists creator_content_user_idx on public.creator_content (user_id, created_at desc);
create unique index if not exists creator_content_link_once on public.creator_content (user_id, lower(link));
create index if not exists creator_content_reviewer_idx on public.creator_content (reviewed_by);
alter table public.creator_content enable row level security;

-- Applicants and members see their own rows; admins see all (the queue is admin-only, like the badge and Plus
-- functions it calls).
drop policy if exists "own creator applications" on public.creator_applications;
create policy "own creator applications" on public.creator_applications for select to authenticated
  using (user_id = (select auth.uid()) or public.is_site_admin());
drop policy if exists "own creator content" on public.creator_content;
create policy "own creator content" on public.creator_content for select to authenticated
  using (user_id = (select auth.uid()) or public.is_site_admin());
revoke all on public.creator_applications, public.creator_content from public, anon;
grant select on public.creator_applications, public.creator_content to authenticated;

-- Apply. Only verified creators (verified_as set), one open application at a time, 30 days after a rejection.
create or replace function public.apply_creator(p_followers int, p_content_link text, p_note text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); rid uuid; last_rej timestamptz;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('creator_program') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'That account is banned'; end if;
  if (select verified_as from public.profiles where id = me) is null then raise exception 'Get verified first'; end if;
  if exists (select 1 from public.profiles where id = me and badges && array['creator_1', 'creator_2', 'creator_3']) then
    raise exception 'You''re already in the Creator Program';
  end if;
  perform 1 from public.profiles where id = me for update;
  if exists (select 1 from public.creator_applications where user_id = me and status = 'pending') then
    raise exception 'You already have an application waiting for review';
  end if;
  select max(reviewed_at) into last_rej from public.creator_applications where user_id = me and status = 'rejected';
  if last_rej is not null and last_rej > now() - interval '30 days' then
    raise exception 'You can apply again 30 days after a rejection';
  end if;
  if p_followers is null or p_followers < 0 then raise exception 'How many followers do you have?'; end if;
  if p_content_link is null or btrim(p_content_link) = '' then raise exception 'Add a link'; end if;
  insert into public.creator_applications (user_id, followers, content_link, note)
  values (me, p_followers, btrim(p_content_link), left(coalesce(p_note, ''), 1000))
  returning id into rid;
  return rid;
end; $$;

-- Admin: approve with a tier (1 Creator, 2 Pro Creator, 3 Elite Creator) or reject with a note.
create or replace function public.review_creator(rid uuid, approve boolean, p_tier int default null, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.creator_applications; months int; badge text; until_at timestamptz;
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  select * into r from public.creator_applications where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status <> 'pending' then raise exception 'Already reviewed'; end if;
  if r.user_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if approve then
    if p_tier is null or p_tier not between 1 and 3 then raise exception 'Pick a tier'; end if;
    if public.is_site_banned(r.user_id) then raise exception 'That account is banned'; end if;
    months := case p_tier when 1 then 3 else 12 end;
    badge := 'creator_' || p_tier;
    update public.profiles set
      badges = array(select distinct unnest(
        array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (b = any(tiers) and b <> badge)) || badge)),
      shown_badge = case when shown_badge = any(tiers) then badge else shown_badge end,
      plus_until = greatest(coalesce(plus_until, now()), now()) + make_interval(days => 31 * months)
      where id = r.user_id
      returning plus_until into until_at;
    update public.creator_applications set status = 'approved', tier = p_tier, plus_months = months,
      reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = rid;
    insert into public.mod_log (actor, action, target_id, reason) values
      ((select auth.uid()), 'creator_approved', r.user_id, 'Tier ' || p_tier || ', ' || months || ' months Plus' || case when p_note <> '' then ': ' || p_note else '' end),
      ((select auth.uid()), 'badge_given', r.user_id, badge),
      ((select auth.uid()), 'plus_gift', r.user_id, 'Until ' || to_char(until_at, 'YYYY-MM-DD') || ': Creator Program tier ' || p_tier);
    begin
      perform public.rt_profile_changed(array[r.user_id]);
    exception when others then
      raise warning 'review_creator: profile cache ping for % failed: %', r.user_id, sqlerrm;
    end;
  else
    if length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
    update public.creator_applications set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = rid;
    insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'creator_rejected', r.user_id, p_note);
  end if;
end; $$;

-- Member: send in a video or post about Yapper. Up to 3 waiting, each link once.
create or replace function public.submit_creator_content(p_link text, p_note text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); cid uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('creator_program') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'That account is banned'; end if;
  if not exists (select 1 from public.profiles where id = me and badges && array['creator_1', 'creator_2', 'creator_3']) then
    raise exception 'Join the Creator Program first';
  end if;
  perform 1 from public.profiles where id = me for update;
  if (select count(*) from public.creator_content where user_id = me and status = 'pending') >= 3 then
    raise exception 'You have 3 waiting for review already. Wait for those first.';
  end if;
  if p_link is null or btrim(p_link) = '' then raise exception 'Add a link'; end if;
  if exists (select 1 from public.creator_content where user_id = me and lower(link) = lower(btrim(p_link))) then
    raise exception 'You already sent that link';
  end if;
  insert into public.creator_content (user_id, link, note) values (me, btrim(p_link), left(coalesce(p_note, ''), 500))
  returning id into cid;
  return cid;
end; $$;

-- Admin: an approved piece adds a month of Plus (on top of what they have); a rejection needs a note.
create or replace function public.review_creator_content(cid uuid, approve boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare c public.creator_content; until_at timestamptz;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  select * into c from public.creator_content where id = cid for update;
  if c.id is null then raise exception 'Not found'; end if;
  if c.status <> 'pending' then raise exception 'Already reviewed'; end if;
  if c.user_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if approve then
    if public.is_site_banned(c.user_id) then raise exception 'That account is banned'; end if;
    update public.profiles set plus_until = greatest(coalesce(plus_until, now()), now()) + make_interval(days => 31 * c.reward_months)
      where id = c.user_id returning plus_until into until_at;
    update public.creator_content set status = 'approved', reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = cid;
    insert into public.mod_log (actor, action, target_id, reason) values
      ((select auth.uid()), 'content_approved', c.user_id, left(c.link, 200) || case when p_note <> '' then ': ' || p_note else '' end),
      ((select auth.uid()), 'plus_gift', c.user_id, 'Until ' || to_char(until_at, 'YYYY-MM-DD') || ': Creator Program content');
    begin
      perform public.rt_profile_changed(array[c.user_id]);
    exception when others then
      raise warning 'review_creator_content: profile cache ping for % failed: %', c.user_id, sqlerrm;
    end;
  else
    if length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
    update public.creator_content set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = cid;
    insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'content_rejected', c.user_id, left(c.link, 100) || ': ' || p_note);
  end if;
end; $$;

-- Admin: out of the program (badge off; Plus they already got stays until it runs out). They can apply again.
create or replace function public.revoke_creator(uid uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare tiers constant text[] := array['creator_1', 'creator_2', 'creator_3']; n int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.profiles set
    badges = array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (b = any(tiers))),
    shown_badge = case when shown_badge = any(tiers) then null else shown_badge end
    where id = uid and badges && tiers;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Not in the Creator Program'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'creator_revoked', uid, left(btrim(coalesce(p_note, '')), 300));
  begin
    perform public.rt_profile_changed(array[uid]);
  exception when others then
    raise warning 'revoke_creator: profile cache ping for % failed: %', uid, sqlerrm;
  end;
end; $$;

revoke all on function public.apply_creator(int, text, text), public.review_creator(uuid, boolean, int, text),
  public.submit_creator_content(text, text), public.review_creator_content(uuid, boolean, text), public.revoke_creator(uuid, text) from public, anon;
grant execute on function public.apply_creator(int, text, text), public.review_creator(uuid, boolean, int, text),
  public.submit_creator_content(text, text), public.review_creator_content(uuid, boolean, text), public.revoke_creator(uuid, text) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('creator_program', 'Creator Program', 'Verified creators apply (Settings, Creator Program, and /creators); admins approve in Mod Center with a badge tier and Plus; every approved video or post adds a month of Plus', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
reset lock_timeout;
