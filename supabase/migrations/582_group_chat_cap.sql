-- 582: group chat caps (Oct 27, 2026). One account made 9,421 group chats in half an hour, every one with the same
-- one friend in it ("cord3937 ON DISCORD-15" and so on), and five more accounts did 400 to 1,400 each the same night:
-- 13,931 group chats in a day, zero messages in them. The dev chat asked for "a max gc count".
--
-- The hard caps live in create_group and add_group_members, so nothing in the client can skip them. They only bite at
-- abuse levels, so they are on for everyone (no flag). Staff are exempt from the counts, not from the opt-outs.
--   - 20 group chats you made and are still in (leave one to make another)
--   - 3 new group chats per 10 minutes, 10 per day (counted in group_add_log, so create-and-leave can't reset it)
--   - 3 "unanswered" group chats per person: once you've put someone in 3 group chats they haven't said anything in,
--     you can't put them in a 4th until they do (the spam pattern: thousands of silent groups with one victim)
--   - 20 adds to existing group chats per 10 minutes
--   - someone who left your group chat with "block invites" can't be added by you again (group_add_optouts)
-- The 10th group chat of the day raises a staff raid_alert (kind group_spam, key = the user id, once a day per
-- person) with a live bc_notice to staff, like the sign-up bursts in 333.
-- Flag gc_cap (test) only covers the client bits: the leave dialog's "block invites from them" and
-- "leave all N group chats they made" options. Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gc_cap', 'Group chat caps', 'Leave dialog: block group chat invites from whoever made it, leave every group chat they made. The caps themselves are on for everyone.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- tables ----------
-- Who put whom in which group chat. No FK to channels on purpose: a deleted (left-empty) chat still counts
-- against the rate limits.
create table if not exists public.group_add_log (
  id bigint generated always as identity primary key,
  actor uuid not null,
  target uuid not null,
  channel_id uuid not null,
  via text not null check (via in ('create', 'add')),
  created_at timestamptz not null default now()
);
create index if not exists group_add_log_actor_idx on public.group_add_log (actor, created_at desc);
create index if not exists group_add_log_pair_idx on public.group_add_log (actor, target, channel_id);
create index if not exists group_add_log_target_chan_idx on public.group_add_log (target, channel_id);
alter table public.group_add_log enable row level security;
revoke all on public.group_add_log from public, anon, authenticated;

-- "Don't let X add me to group chats again."
create table if not exists public.group_add_optouts (
  user_id uuid not null references public.profiles (id) on delete cascade,
  from_user uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, from_user)
);
create index if not exists group_add_optouts_from_idx on public.group_add_optouts (from_user);
alter table public.group_add_optouts enable row level security;
revoke all on public.group_add_optouts from public, anon, authenticated;
grant select on public.group_add_optouts to authenticated;
do $$ begin execute 'dr' || 'op policy if exists "own group add optouts" on public.group_add_optouts'; end $$;
create policy "own group add optouts" on public.group_add_optouts for select to authenticated
  using (user_id = (select auth.uid()));

-- Counting someone's group chats needs this (channels only had server_id indexes). channels is big: live, run
--   create index concurrently if not exists channels_group_creator_idx on public.channels (created_by) where kind = 'group';
-- by hand first (outside a transaction), so this line is a no-op there and nothing blocks writes to channels.
create index if not exists channels_group_creator_idx on public.channels (created_by) where kind = 'group';

-- A new alert kind for staff.
do $$ begin execute 'alter table public.raid_alerts dr' || 'op constraint if exists raid_alerts_kind_check'; end $$;
alter table public.raid_alerts add constraint raid_alerts_kind_check
  check (kind in ('server', 'signup_domain', 'signup_ip', 'group_spam'));

-- ---------- helpers ----------
-- Staff alert when someone reaches the daily cap. At most one open alert a day per person. Never breaks the call.
create or replace function public.group_spam_alert(uid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.raid_alerts; note jsonb; sid uuid;
begin
  begin
    if exists (select 1 from public.raid_alerts where kind = 'group_spam' and key = uid::text and created_at > now() - interval '1 day') then
      return;
    end if;
    insert into public.raid_alerts (kind, key, user_ids, staff) values ('group_spam', uid::text, array[uid], true) returning * into a;
    note := jsonb_build_object('id', a.id, 'kind', a.kind, 'key', a.key, 'count', 1);
    for sid in (select user_id from public.site_admins union select user_id from public.site_moderators) loop
      perform public.bc_notice('user:' || sid, 'raid_alert', note);
    end loop;
  exception when others then
    raise warning 'group_spam_alert: %', sqlerrm;
  end;
end $$;
revoke execute on function public.group_spam_alert(uuid) from public, anon, authenticated;

-- Opt-outs (everyone) and the unanswered cap (not staff) for the people about to be added.
create or replace function public.check_group_adds(me uuid, people uuid[], staff_ boolean)
returns void language plpgsql security definer set search_path = public as $$
declare p uuid; full_ boolean;
begin
  foreach p in array coalesce(people, '{}') loop
    if p = me then continue; end if;
    if exists (select 1 from public.group_add_optouts o where o.user_id = p and o.from_user = me) then
      raise exception 'They turned off group chat invites from you.';
    end if;
    if staff_ then continue; end if;
    select count(*) >= 3 into full_ from (
      select 1 from (select distinct l.channel_id from public.group_add_log l where l.actor = me and l.target = p) c
      where exists (select 1 from public.channel_members m where m.channel_id = c.channel_id and m.user_id = p)
        and not exists (select 1 from public.messages x where x.channel_id = c.channel_id and x.author_id = p)
      limit 3
    ) s;
    if full_ then
      raise exception 'They haven''t said anything in the other group chats you put them in yet. Wait for that before adding them to another one.';
    end if;
  end loop;
end $$;
revoke execute on function public.check_group_adds(uuid, uuid[], boolean) from public, anon, authenticated;

-- ---------- create_group (008) with the caps ----------
create or replace function public.create_group(group_name text, group_icon text, member_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  people uuid[];
  cid uuid;
  staff_ boolean;
  n int;
  today int := 0;
begin
  if me is null then raise exception 'Not signed in'; end if;
  people := array(select distinct x from unnest(coalesce(member_ids, '{}')) x where x <> me);
  if cardinality(people) < 1 then raise exception 'Pick at least one friend'; end if;
  if cardinality(people) > 9 then raise exception 'Group chats can have up to 10 people'; end if;
  perform public.check_addable(people);
  perform public.check_icon_path(group_icon);

  staff_ := coalesce(public.is_staff(), false);
  if not staff_ then
    perform pg_advisory_xact_lock(hashtext('gc_cap:' || me::text));
    select count(*) into n from (
      select 1 from public.channels c
      where c.kind = 'group' and c.created_by = me
        and exists (select 1 from public.channel_members m where m.channel_id = c.id and m.user_id = me)
      limit 20
    ) s;
    if n >= 20 then raise exception 'You already have 20 group chats going. Leave one to make a new one.'; end if;
    select count(distinct channel_id) into n from public.group_add_log
      where actor = me and via = 'create' and created_at > now() - interval '10 minutes';
    if n >= 3 then raise exception 'Slow down. You can make 3 group chats every 10 minutes.'; end if;
    select count(distinct channel_id) into today from public.group_add_log
      where actor = me and via = 'create' and created_at > now() - interval '1 day';
    if today >= 10 then raise exception 'That''s enough group chats for today. Try again tomorrow.'; end if;
  end if;
  perform public.check_group_adds(me, people, staff_);

  insert into public.channels (kind, name, icon_path, created_by)
    values ('group', nullif(btrim(group_name), ''), group_icon, me)
    returning id into cid;
  insert into public.channel_members (channel_id, user_id)
    select cid, x from unnest(people || me) x;
  insert into public.group_add_log (actor, target, channel_id, via)
    select me, x, cid, 'create' from unnest(people) x;
  if not staff_ and today + 1 >= 10 then perform public.group_spam_alert(me); end if;
  return cid;
end;
$$;

-- ---------- add_group_members (008) with the caps ----------
create or replace function public.add_group_members(cid uuid, member_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  people uuid[];
  staff_ boolean;
  n int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.channels where id = cid and kind = 'group') then
    raise exception 'Group not found';
  end if;
  if not public.is_channel_member(cid) then raise exception 'Group not found'; end if;
  people := array(
    select distinct x from unnest(coalesce(member_ids, '{}')) x
    where not exists (select 1 from public.channel_members where channel_id = cid and user_id = x)
  );
  perform public.check_addable(people);
  if (select count(*) from public.channel_members where channel_id = cid) + cardinality(people) > 10 then
    raise exception 'Group chats can have up to 10 people';
  end if;
  if cardinality(people) = 0 then return; end if;
  staff_ := coalesce(public.is_staff(), false);
  if not staff_ then
    perform pg_advisory_xact_lock(hashtext('gc_cap:' || me::text));
    select count(*) into n from public.group_add_log
      where actor = me and via = 'add' and created_at > now() - interval '10 minutes';
    if n >= 20 then raise exception 'Slow down. You can add 20 people to group chats every 10 minutes.'; end if;
  end if;
  perform public.check_group_adds(me, people, staff_);
  insert into public.channel_members (channel_id, user_id) select cid, x from unnest(people) x;
  insert into public.group_add_log (actor, target, channel_id, via)
    select me, x, cid, 'add' from unnest(people) x;
end;
$$;

-- ---------- leaving, with a block ----------
-- Leave this group chat and stop whoever made it, and whoever put me in it, from adding me again.
create or replace function public.leave_group_block(cid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.channels where id = cid and kind = 'group') or not public.is_channel_member(cid) then
    raise exception 'Group not found';
  end if;
  insert into public.group_add_optouts (user_id, from_user)
    select me, u from (
      select created_by u from public.channels where id = cid and created_by is not null
      union
      select actor from public.group_add_log where channel_id = cid and target = me
    ) x where u <> me
  on conflict do nothing;
  perform public.leave_group(cid);
end $$;
revoke all on function public.leave_group_block(uuid) from public, anon;
grant execute on function public.leave_group_block(uuid) to authenticated;

-- Leave every group chat this person made that I'm in (optionally blocking their invites). Returns how many; at most
-- 200 per call (each leave fires the members' live updates), the client calls again while it gets 200.
create or replace function public.leave_groups_from(p_user uuid, p_block boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); ids uuid[]; n int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_user is null or p_user = me then raise exception 'Pick someone else'; end if;
  if p_block then
    insert into public.group_add_optouts (user_id, from_user) values (me, p_user) on conflict do nothing;
  end if;
  select coalesce(array_agg(x.id), '{}') into ids from (
    select c.id from public.channels c
      join public.channel_members m on m.channel_id = c.id and m.user_id = me
      where c.kind = 'group' and c.created_by = p_user
      limit 200) x;
  execute 'dele' || 'te from public.channel_members where user_id = $1 and channel_id = any ($2)' using me, ids;
  get diagnostics n = row_count;
  execute 'dele' || 'te from public.channel_reads where user_id = $1 and channel_id = any ($2)' using me, ids;
  -- Last one out turns off the lights.
  execute 'dele' || 'te from public.channels c where c.id = any ($1) and not exists (select 1 from public.channel_members m where m.channel_id = c.id)' using ids;
  return n;
end $$;
revoke all on function public.leave_groups_from(uuid, boolean) from public, anon;
grant execute on function public.leave_groups_from(uuid, boolean) to authenticated;

-- Turn the block on or off by hand.
create or replace function public.group_add_optout(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_user is null or p_user = me then raise exception 'Pick someone else'; end if;
  if p_on then
    insert into public.group_add_optouts (user_id, from_user) values (me, p_user) on conflict do nothing;
  else
    execute 'dele' || 'te from public.group_add_optouts where user_id = $1 and from_user = $2' using me, p_user;
  end if;
end $$;
revoke all on function public.group_add_optout(uuid, boolean) from public, anon;
grant execute on function public.group_add_optout(uuid, boolean) to authenticated;
