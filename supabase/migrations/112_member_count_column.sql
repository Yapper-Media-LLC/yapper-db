-- servers.member_count kept by trigger: counting 28k rows of server_members on every start-up (with
-- 20k heap fetches because autovacuum can't keep up with the join rate) was itself a cost. The member
-- slice is now plpgsql with explicit id arrays so the planner cannot flip it into a scan of every member.

alter table public.servers add column if not exists member_count integer not null default 0;
update public.servers s set member_count = (select count(*) from public.server_members m where m.server_id = s.id);

create or replace function public.bump_member_count() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'INSERT' then
    update public.servers set member_count = member_count + 1 where id = new.server_id;
  elsif tg_op = 'DELETE' then
    update public.servers set member_count = greatest(0, member_count - 1) where id = old.server_id;
  end if;
  return null;
end $$;
create or replace trigger server_members_count after insert or delete on public.server_members for each row execute function public.bump_member_count();

create or replace function public.server_member_counts(sids uuid[])
returns table(server_id uuid, n bigint)
language sql stable security definer set search_path to 'public' as $$
  select s.id, s.member_count::bigint from public.servers s where s.id = any(sids);
$$;

create or replace function public.server_members_slice(sids uuid[])
returns table(server_id uuid, user_id uuid, nickname text, joined_at timestamptz)
language plpgsql stable security definer set search_path to 'public' as $$
declare big uuid[]; small uuid[]; onl uuid[]; me uuid := auth.uid();
begin
  select coalesce(array_agg(id), '{}'::uuid[]) into big from public.servers where id = any(sids) and member_count > 3000;
  select coalesce(array_agg(id), '{}'::uuid[]) into small from public.servers where id = any(sids) and member_count <= 3000;
  if cardinality(big) = 0 then
    return query select sm.server_id, sm.user_id, sm.nickname, sm.joined_at from public.server_members sm where sm.server_id = any(small);
    return;
  end if;
  select coalesce(array_agg(p.user_id), '{}'::uuid[]) into onl from public.presence p where p.last_seen > now() - interval '10 minutes';
  return query
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at from public.server_members sm where sm.server_id = any(small)
    union
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at from public.server_members sm where sm.server_id = any(big) and sm.user_id = me
    union
    -- Every join below is a lateral with limit 1: one index probe per row, never a scan of the whole table.
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
    from public.roles r
    join public.member_roles mr on mr.role_id = r.id
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = mr.server_id and x.user_id = mr.user_id limit 1) sm
    where r.server_id = any(big) and r.auto = 'none'
    union
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
    from public.member_roles mr
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = mr.server_id and x.user_id = mr.user_id limit 1) sm
    where mr.server_id = any(big) and mr.manual
    union
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
    from unnest(onl) as u(user_id)
    cross join unnest(big) as b(server_id)
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = b.server_id and x.user_id = u.user_id limit 1) sm
    union
    select r.server_id, r.user_id, r.nickname, r.joined_at
    from unnest(big) as b(server_id)
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = b.server_id order by x.joined_at desc limit 300) r;
end $$;
