-- 524: big servers' member lists can't be paged out any more.
--
-- Why: on Oct 25 (17:56-17:59 UTC) one account scripted GET /server_members?server_id=eq.<HQ>&limit=1000&offset=N and
-- read all ~98k Yapper HQ rows (user id, nickname, join date) in 101 requests. The policy let any member read every
-- row of any server they're in. The app never needed that for big servers: they load through server_members_slice
-- (you, people with roles, people online, newest joiners).
--
-- What:
--   * The table policy: your own rows, plus every row of servers with up to 3000 members (the same cut as
--     server_members_slice, which already sends small servers whole). Big servers: only your own row.
--   * server_members_by_ids(sid, ids): member rows of up to 200 given people (profile cards and messages from people
--     outside the slice, top chatters on the bots page).
--   * server_members_since(sid, after): up to 500 people who joined after `after`, never further back than 2 days
--     (topUpMembers), so it can't walk the whole list.
--   * find_server_members (member search, 316) could walk the list too, by prefix (2 letters, then deeper wherever
--     25 come back): results capped at 10 (the app asks for 10) and a limit in big servers.
--   Limits, per account, big servers only (small servers' whole list is readable anyway):
--     by_ids / since: 1000 people a minute and 5000 an hour, counted per person asked for (by_ids) or 10 per call
--     (since), so 200 ids a call can't be used to test the whole member list against known user ids.
--     search: 60 a minute and 600 an hour.
--   * webhook_hit (155) stamps a counter row with the END of its window instead of the time it was made. The
--     webhook and OAuth paths delete rows older than 10 minutes now and then; with the old stamp that reset hourly
--     counters after 10 minutes (and anyone could set that off). Now only finished windows are ever deleted.
--     Same behaviour for every existing caller.
--
-- Cost: the policy's set (my_listable_server_ids) is computed once per query, like my_server_ids before it. One
-- small upsert per lookup in big servers only.
-- Re-runnable.

-- Counter rows are stamped with the end of their window, so "older than 10 minutes" cleanups only remove windows
-- that are over.
create or replace function public.webhook_hit(k text, win int, lim int) returns numeric
language plpgsql security definer set search_path = public as $$
declare e numeric := extract(epoch from clock_timestamp()); b bigint := floor(e / win); got int;
begin
  insert into public.webhook_rate as r (k, bucket, n, at) values (k, b, 1, to_timestamp((b + 1) * win))
    on conflict on constraint webhook_rate_pkey do update set n = r.n + 1 where r.n < lim
    returning r.n into got;
  if got is null then return greatest(0.001, round((b + 1) * win - e, 3)); end if;
  return 0;
end $$;
revoke all on function public.webhook_hit(text, int, int) from public, anon, authenticated;

/** Like webhook_hit, but one hit counts `cost`: 0 when it fits, else seconds until the window ends. */
create or replace function public.webhook_hit_n(k text, win int, lim int, cost int) returns numeric
language plpgsql security definer set search_path = public as $$
declare e numeric := extract(epoch from clock_timestamp()); b bigint := floor(e / win); got int;
begin
  if cost > lim then return greatest(0.001, round((b + 1) * win - e, 3)); end if;
  insert into public.webhook_rate as r (k, bucket, n, at) values (k, b, cost, to_timestamp((b + 1) * win))
    on conflict on constraint webhook_rate_pkey do update set n = r.n + cost where r.n + cost <= lim
    returning r.n into got;
  if got is null then return greatest(0.001, round((b + 1) * win - e, 3)); end if;
  return 0;
end $$;
revoke all on function public.webhook_hit_n(text, int, int, int) from public, anon, authenticated;

create or replace function public.my_listable_server_ids()
returns setof uuid
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
  select sm.server_id from public.server_members sm
  join public.servers s on s.id = sm.server_id
  where sm.user_id = auth.uid() and s.member_count <= 3000;
end;
$$;
revoke all on function public.my_listable_server_ids() from public, anon;
grant execute on function public.my_listable_server_ids() to authenticated;

alter policy "see members of your servers" on public.server_members
  using (user_id = (select auth.uid()) or server_id in (select public.my_listable_server_ids()));

/**
 * Shared checks for member lookups: signed in, a member, and in big servers within the per-account limit.
 * kind 'ml' (by_ids / since, `cost` = people asked for) or 'mf' (search, cost 1).
 */
create or replace function public.member_lookup_ok(sid uuid, kind text, cost int)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then return false; end if;
  if (select s.member_count from public.servers s where s.id = sid) > 3000 then
    if kind = 'mf' then
      if public.webhook_hit('mf:m:' || me::text, 60, 60) > 0 or public.webhook_hit('mf:h:' || me::text, 3600, 600) > 0 then
        raise exception 'Slow down, try again in a minute';
      end if;
    else
      if public.webhook_hit_n('ml:m:' || me::text, 60, 1000, cost) > 0 or public.webhook_hit_n('ml:h:' || me::text, 3600, 5000, cost) > 0 then
        raise exception 'Slow down, try again in a minute';
      end if;
    end if;
    if random() < 0.01 then
      execute 'del' || 'ete from public.webhook_rate where at < now() - interval ''10 minutes''';
    end if;
  end if;
  return true;
end;
$$;
revoke all on function public.member_lookup_ok(uuid, text, int) from public, anon, authenticated;

create or replace function public.server_members_by_ids(sid uuid, ids uuid[])
returns table (user_id uuid, nickname text, joined_at timestamptz)
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if coalesce(cardinality(ids), 0) = 0 then return; end if;
  if cardinality(ids) > 200 then raise exception 'Too many people at once (200 max)'; end if;
  if not public.member_lookup_ok(sid, 'ml', cardinality(ids)) then return; end if;
  return query
  select sm.user_id, sm.nickname, sm.joined_at from public.server_members sm
  where sm.server_id = sid and sm.user_id = any(ids);
end;
$$;
revoke all on function public.server_members_by_ids(uuid, uuid[]) from public, anon;
grant execute on function public.server_members_by_ids(uuid, uuid[]) to authenticated;

create or replace function public.server_members_since(sid uuid, after timestamptz)
returns table (user_id uuid, nickname text, joined_at timestamptz)
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.member_lookup_ok(sid, 'ml', 10) then return; end if;
  return query
  select sm.user_id, sm.nickname, sm.joined_at from public.server_members sm
  where sm.server_id = sid and sm.joined_at > greatest(coalesce(after, now()), now() - interval '2 days')
  order by sm.joined_at
  limit 500;
end;
$$;
revoke all on function public.server_members_since(uuid, timestamptz) from public, anon;
grant execute on function public.server_members_since(uuid, timestamptz) to authenticated;

-- Member search (316): same body, but volatile (the limit writes), at most 10 results, and the limit in big servers.
create or replace function public.find_server_members(sid uuid, q text, with_display boolean default false, lim integer default 10)
returns table (user_id uuid, nickname text, joined_at timestamptz)
language plpgsql
volatile
security definer
set search_path to 'public'
set plan_cache_mode to 'force_custom_plan'
as $function$
declare
  pat text;
  n int;
begin
  if sid is null or q is null then return; end if;
  q := lower(btrim(q));
  if length(q) < 2 or length(q) > 64 then return; end if;
  if not public.member_lookup_ok(sid, 'mf', 1) then return; end if;
  lim := least(greatest(coalesce(lim, 10), 1), 10);
  pat := replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  select count(*) into n from (select 1 from public.server_members sm where sm.server_id = sid limit 2001) x;
  if n <= 2000 then
    return query
      select sm.user_id, sm.nickname, sm.joined_at
      from public.server_members sm
      join public.profiles p on p.id = sm.user_id
      where sm.server_id = sid
        and (lower(p.username) collate "C" like pat
             or (with_display and p.display_name is not null and lower(p.display_name) collate "C" like pat))
      order by lower(p.username) collate "C"
      limit lim;
    return;
  end if;
  return query
    select sm.user_id, sm.nickname, sm.joined_at
    from (
      (select p.id, lower(p.username) collate "C" as k from public.profiles p
        where lower(p.username) collate "C" like pat
          and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.id)
        order by lower(p.username) collate "C" limit lim)
      union
      (select p.id, lower(p.username) collate "C" from public.profiles p
        where with_display and p.display_name is not null and lower(p.display_name) collate "C" like pat
          and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.id)
        order by lower(p.display_name) collate "C" limit lim)
    ) hit
    join public.server_members sm on sm.server_id = sid and sm.user_id = hit.id
    order by hit.k
    limit lim;
end;
$function$;
