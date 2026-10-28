-- 588: friend request origin (flag friend_origin, test) and mass remove (flag mass_remove, test). From AutumnChills'
-- safety list:
--   7. Friends, All and Pending say how a request came: the server you were both in when it was sent
--      (friendships.via_server, kept after accepting) and how many friends you have in common (friends_info()).
--   5. Remove many friends at once (remove_friends; skipping people whose DM you pinned is the client's job) and leave
--      many servers at once (leave_servers: pick them, or a whole folder). Servers you own are skipped, not refused.
-- send_friend_request gets a third argument, via_server (default null, so old calls still work); the old two-argument
-- function goes away so PostgREST has one to pick. The server only sticks when both people are in it. Re-runnable.

set lock_timeout = '5s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('friend_origin', 'Friend request origin', 'Friends, All and Pending: which server the request came from and how many mutual friends.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mass_remove', 'Mass remove', 'Remove many friends at once (pinned DMs skipped) and leave many servers at once, by pick or by folder.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

alter table public.friendships add column if not exists via_server uuid references public.servers (id) on delete set null;
create index if not exists friendships_via_server_idx on public.friendships (via_server) where via_server is not null;

-- ---------- 7: where the request came from ----------
do $$ begin execute 'dr' || 'op function if exists public.send_friend_request(text, text)'; end $$;
create or replace function public.send_friend_request(target_username text, note text default null, via_server uuid default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  target uuid;
  existing public.friendships;
  pref text;
  sid uuid := null;
  clean text := nullif(btrim(regexp_replace(coalesce(send_friend_request.note, ''), '\s+', ' ', 'g')), '');
begin
  if me is null then raise exception 'Not signed in'; end if;
  if clean is not null and not public.feature_on_for_me('friend_notes') then clean := null; end if;
  if clean is not null then
    if char_length(clean) > 100 then raise exception 'Notes are up to 100 characters' using errcode = 'check_violation'; end if;
    if public.has_slur(clean) then
      raise exception 'That contains a slur, so it wasn''t sent. Keep it respectful.' using errcode = 'check_violation';
    end if;
    if public.has_adult_link(clean) then
      raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
    end if;
  end if;
  select id into target from public.profiles where lower(username) = lower(btrim(target_username));
  if target is null then raise exception 'Hm, that didn''t work. Double check the username.'; end if;
  if target = me then raise exception 'You can''t friend yourself (we checked)'; end if;
  if public.is_bot_user(target) then raise exception 'Bots can''t be friends' using errcode = 'check_violation'; end if;
  if public.is_blocked_between(me, target) then
    raise exception 'Hm, that didn''t work. Double check the username.';
  end if;

  select * into existing from public.friendships
  where least(requester, addressee) = least(me, target)
    and greatest(requester, addressee) = greatest(me, target);

  if existing.id is not null then
    if existing.status = 'accepted' then raise exception 'You''re already friends'; end if;
    if existing.requester = me then raise exception 'Request already sent'; end if;
    update public.friendships set status = 'accepted', accepted_at = now() where id = existing.id;
    return 'accepted';
  end if;

  if (select count(*) from public.friendships where requester = me and status = 'pending') >= 100 then
    raise exception 'Too many pending requests';
  end if;
  if exists (select 1 from public.friend_request_declines d
             where d.requester = me and d.addressee = target and d.declined_at > now() - interval '24 hours') then
    raise exception 'You sent them a request not long ago. Try again tomorrow.';
  end if;
  if clean is not null then
    select coalesce(dms_from, 'friends') into pref from public.profiles where id = target;
    if not (pref = 'everyone' or (pref = 'servers' and exists (
      select 1 from public.server_members a join public.server_members b on a.server_id = b.server_id
      where a.user_id = me and b.user_id = target))) then
      clean := null;
    end if;
  end if;
  -- The server only counts when you're both in it right now (the client sends whatever is open).
  if via_server is not null and exists (
      select 1 from public.server_members a join public.server_members b on a.server_id = b.server_id
      where a.server_id = via_server and a.user_id = me and b.user_id = target) then
    sid := via_server;
  end if;
  insert into public.friendships (requester, addressee, note, via_server) values (me, target, clean, sid);
  return 'sent';
end;
$$;
revoke all on function public.send_friend_request(text, text, uuid) from public, anon;
grant execute on function public.send_friend_request(text, text, uuid) to authenticated;

-- For the Friends page: every friendship of mine (pending both ways and accepted) with the server it came from and
-- how many of my friends are also theirs. One query; the page calls it when it opens, not at startup.
create or replace function public.friends_info()
returns table (other uuid, via_server uuid, mutual_friends int)
language plpgsql
stable
security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on_for_me('friend_origin') then return; end if;
  return query
    with mine as (
      select case when f.requester = me then f.addressee else f.requester end as o, f.via_server as v, f.status as st
      from public.friendships f where f.requester = me or f.addressee = me
    ),
    myf as (select o from mine where st = 'accepted')
    select m.o, m.v,
      (select count(*)::int from public.friendships f
        where f.status = 'accepted'
          and ((f.requester = m.o and f.addressee in (select o from myf)) or (f.addressee = m.o and f.requester in (select o from myf))))
    from mine m;
end;
$$;
revoke all on function public.friends_info() from public, anon;
grant execute on function public.friends_info() to authenticated;

-- ---------- 5: mass remove ----------
-- Remove up to 200 friends in one go. Returns how many went.
create or replace function public.remove_friends(others uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); ids uuid[]; n int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on_for_me('mass_remove') then raise exception 'Not available yet'; end if;
  ids := (select array_agg(distinct x) from unnest(coalesce(others, '{}')) x where x <> me);
  if cardinality(coalesce(ids, '{}')) > 200 then raise exception 'Up to 200 at a time'; end if;
  execute 'del' || 'ete from public.friendships where (requester = $1 and addressee = any($2)) or (addressee = $1 and requester = any($2))'
    using me, ids;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.remove_friends(uuid[]) from public, anon;
grant execute on function public.remove_friends(uuid[]) to authenticated;

-- Leave up to 100 servers in one go. Servers you own are skipped (delete them instead). Returns how many you left.
create or replace function public.leave_servers(sids uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); ids uuid[]; sid uuid; n int := 0;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on_for_me('mass_remove') then raise exception 'Not available yet'; end if;
  ids := (select array_agg(distinct x) from unnest(coalesce(sids, '{}')) x);
  if cardinality(coalesce(ids, '{}')) > 100 then raise exception 'Up to 100 at a time'; end if;
  for sid in (select m.server_id from public.server_members m
              where m.user_id = me and m.server_id = any(ids)
                and not exists (select 1 from public.servers s where s.id = m.server_id and s.owner_id = me)) loop
    perform public.leave_server(sid);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.leave_servers(uuid[]) from public, anon;
grant execute on function public.leave_servers(uuid[]) to authenticated;
