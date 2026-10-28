-- Staff votes (applied live Oct 14): moderators can vote to remove and ban another moderator.
-- The vote passes when more than app_settings.staff_vote_pct percent of the other active staff
-- (admins plus unpaused moderators, not counting the target) have voted. With 50% that is 2 of 2,
-- 2 of 3, 3 of 4, 3 of 5. Admins can't be voted out. Votes expire after 24 hours.
alter table public.app_settings add column if not exists staff_vote_pct int not null default 50;

create table if not exists public.staff_votes (
  id uuid primary key default gen_random_uuid(),
  target uuid not null references public.profiles (id) on delete cascade,
  opened_by uuid references public.profiles (id) on delete set null,
  reason text not null default '' check (char_length(reason) <= 500),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  outcome text check (outcome in ('passed', 'withdrawn'))
);
create table if not exists public.staff_vote_ballots (
  vote_id uuid not null references public.staff_votes (id) on delete cascade,
  voter uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (vote_id, voter)
);
alter table public.staff_votes enable row level security;
alter table public.staff_vote_ballots enable row level security;
drop policy if exists "staff see votes" on public.staff_votes;
create policy "staff see votes" on public.staff_votes for select to authenticated using (public.is_staff());
drop policy if exists "staff see ballots" on public.staff_vote_ballots;
create policy "staff see ballots" on public.staff_vote_ballots for select to authenticated using (public.is_staff());
-- Writes go through the functions below.

/** Active staff who may vote about `target`: admins and unpaused moderators, minus the target. */
create or replace function public.staff_vote_eligible(target uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from (
    select user_id from public.site_admins
    union
    select user_id from public.site_moderators where suspended_at is null
  ) s where s.user_id <> target;
$$;

/** Ballots needed: strictly more than staff_vote_pct percent of the eligible voters, never more than all of them. */
create or replace function public.staff_vote_needed(target uuid)
returns int language sql stable security definer set search_path = public as $$
  select greatest(1, least(e, floor(p * e / 100.0)::int + 1))
  from (select public.staff_vote_eligible(target) as e, (select staff_vote_pct from public.app_settings limit 1) as p) x;
$$;

/** Count the ballots from people who are still eligible; if enough, remove and ban the target. */
create or replace function public.staff_vote_tally(vid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.staff_votes; n int; needed int;
begin
  select * into v from public.staff_votes where id = vid;
  if v.id is null or v.closed_at is not null then return; end if;
  select count(*) into n from public.staff_vote_ballots b
    where b.vote_id = vid and b.voter <> v.target
      and (exists (select 1 from public.site_admins a where a.user_id = b.voter)
        or exists (select 1 from public.site_moderators m where m.user_id = b.voter and m.suspended_at is null));
  needed := public.staff_vote_needed(v.target);
  if n < needed then return; end if;
  -- Paused rather than removed: powers and badge go at once, and admins still see who it was and why.
  update public.site_moderators set suspended_at = now(), suspended_reason = left('Removed by staff vote: ' || v.reason, 500) where user_id = v.target;
  insert into public.site_bans (user_id, reason, banned_by) values (v.target, left('Staff vote: ' || v.reason, 500), v.opened_by)
    on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  update public.staff_votes set closed_at = now(), outcome = 'passed' where id = vid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'vote_ban', v.target, v.reason || ' (' || n || ' of ' || needed || ' votes)');
end; $$;

create or replace function public.staff_vote_open(uid uuid, why text)
returns uuid language plpgsql security definer set search_path = public as $$
declare vid uuid;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  if uid = auth.uid() then raise exception 'Not yourself'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins can''t be voted out'; end if;
  if not exists (select 1 from public.site_moderators where user_id = uid and suspended_at is null) then raise exception 'They aren''t an active moderator'; end if;
  if length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  if exists (select 1 from public.staff_votes where target = uid and closed_at is null and created_at > now() - interval '24 hours') then
    raise exception 'There''s already an open vote about them';
  end if;
  insert into public.staff_votes (target, opened_by, reason) values (uid, auth.uid(), left(trim(why), 500)) returning id into vid;
  insert into public.staff_vote_ballots (vote_id, voter) values (vid, auth.uid());
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'vote_opened', uid, left(trim(why), 500));
  perform public.staff_vote_tally(vid);
  return vid;
end; $$;

create or replace function public.staff_vote_cast(vid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.staff_votes;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into v from public.staff_votes where id = vid;
  if v.id is null or v.closed_at is not null or v.created_at < now() - interval '24 hours' then raise exception 'That vote is closed'; end if;
  if v.target = auth.uid() then raise exception 'You can''t vote about yourself'; end if;
  insert into public.staff_vote_ballots (vote_id, voter) values (vid, auth.uid()) on conflict do nothing;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'vote_cast', v.target, v.reason);
  perform public.staff_vote_tally(vid);
end; $$;

/** The person who opened it, or an admin, can withdraw a vote. */
create or replace function public.staff_vote_close(vid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.staff_votes;
begin
  select * into v from public.staff_votes where id = vid;
  if v.id is null or v.closed_at is not null then return; end if;
  if not (v.opened_by = auth.uid() or public.is_site_admin()) then raise exception 'Only whoever started the vote (or an admin) can withdraw it'; end if;
  update public.staff_votes set closed_at = now(), outcome = 'withdrawn' where id = vid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'vote_withdrawn', v.target, v.reason);
end; $$;

/** Open votes with who has voted and how many ballots they need, plus the current percentage. */
create or replace function public.staff_votes_open()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_staff() then jsonb_build_object(
    'pct', (select staff_vote_pct from public.app_settings limit 1),
    'votes', coalesce((select jsonb_agg(jsonb_build_object(
      'id', v.id, 'target', v.target, 'opened_by', v.opened_by, 'reason', v.reason, 'created_at', v.created_at,
      'voters', coalesce((select jsonb_agg(b.voter order by b.created_at) from public.staff_vote_ballots b where b.vote_id = v.id), '[]'::jsonb),
      'eligible', public.staff_vote_eligible(v.target),
      'needed', public.staff_vote_needed(v.target)
    ) order by v.created_at desc)
    from public.staff_votes v where v.closed_at is null and v.created_at > now() - interval '24 hours'), '[]'::jsonb)
  ) else '{}'::jsonb end;
$$;

revoke all on function public.staff_vote_tally(uuid) from public, anon, authenticated;
revoke all on function public.staff_vote_open(uuid, text), public.staff_vote_cast(uuid), public.staff_vote_close(uuid), public.staff_votes_open(), public.staff_vote_eligible(uuid), public.staff_vote_needed(uuid) from public, anon;
grant execute on function public.staff_vote_open(uuid, text), public.staff_vote_cast(uuid), public.staff_vote_close(uuid), public.staff_votes_open(), public.staff_vote_eligible(uuid), public.staff_vote_needed(uuid) to authenticated;

insert into public.feature_flags (key, label, description, mode, users)
  values ('staff_votes', 'Staff votes', 'Moderators vote to remove and ban another moderator (Mod Center tab)', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
  on conflict (key) do nothing;
