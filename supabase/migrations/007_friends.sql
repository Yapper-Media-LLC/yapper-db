-- ============================================================
-- Yapper · Stage 7 · Friends
-- Friend requests, removing friends and blocking.
-- New DMs can only be started with friends.
-- ============================================================

create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references public.profiles (id) on delete cascade,
  addressee uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  check (requester <> addressee)
);
-- One friendship per pair, whichever direction it started from.
create unique index friendships_pair_idx on public.friendships
  (least(requester, addressee), greatest(requester, addressee));
create index friendships_addressee_idx on public.friendships (addressee);

create table public.blocks (
  id uuid primary key default gen_random_uuid(),
  blocker uuid not null references public.profiles (id) on delete cascade,
  blocked uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (blocker, blocked),
  check (blocker <> blocked)
);

alter table public.friendships enable row level security;
alter table public.blocks enable row level security;
-- All changes go through the functions below; people can only read their own rows.
create policy "see your own friendships"
  on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
create policy "see who you blocked"
  on public.blocks for select to authenticated
  using (blocker = auth.uid());

alter publication supabase_realtime add table public.friendships;

-- ---------- Helpers ----------
create or replace function public.is_blocked_between(x uuid, y uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.blocks
    where (blocker = x and blocked = y) or (blocker = y and blocked = x)
  );
$$;

create or replace function public.are_friends(x uuid, y uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.friendships
    where status = 'accepted'
      and least(requester, addressee) = least(x, y)
      and greatest(requester, addressee) = greatest(x, y)
  );
$$;

-- True when this is a DM and either person has blocked the other.
create or replace function public.dm_blocked(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.channels c
    join public.channel_members m1 on m1.channel_id = c.id
    join public.channel_members m2 on m2.channel_id = c.id and m2.user_id <> m1.user_id
    where c.id = cid and c.kind = 'dm'
      and public.is_blocked_between(m1.user_id, m2.user_id)
  );
$$;

-- ---------- Friend actions ----------
create or replace function public.send_friend_request(target_username text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  target uuid;
  existing public.friendships;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select id into target from public.profiles where lower(username) = lower(btrim(target_username));
  if target is null then raise exception 'Hm, that didn''t work. Double check the username.'; end if;
  if target = me then raise exception 'You can''t friend yourself (we checked)'; end if;
  if public.is_blocked_between(me, target) then
    raise exception 'Hm, that didn''t work. Double check the username.';
  end if;

  select * into existing from public.friendships
  where least(requester, addressee) = least(me, target)
    and greatest(requester, addressee) = greatest(me, target);

  if existing.id is not null then
    if existing.status = 'accepted' then raise exception 'You''re already friends'; end if;
    if existing.requester = me then raise exception 'Request already sent'; end if;
    -- They already asked you: sending one back accepts it.
    update public.friendships set status = 'accepted', accepted_at = now() where id = existing.id;
    return 'accepted';
  end if;

  if (select count(*) from public.friendships where requester = me and status = 'pending') >= 100 then
    raise exception 'Too many pending requests';
  end if;
  insert into public.friendships (requester, addressee) values (me, target);
  return 'sent';
end;
$$;

create or replace function public.respond_friend_request(other uuid, accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if accept then
    update public.friendships set status = 'accepted', accepted_at = now()
    where requester = other and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships
    where requester = other and addressee = auth.uid() and status = 'pending';
  end if;
end;
$$;

-- Removes a friend, or cancels a request you sent.
create or replace function public.remove_friend(other uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.friendships
  where least(requester, addressee) = least(auth.uid(), other)
    and greatest(requester, addressee) = greatest(auth.uid(), other);
$$;

create or replace function public.block_user(other uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if other = auth.uid() then raise exception 'You can''t block yourself'; end if;
  if not exists (select 1 from public.profiles where id = other) then raise exception 'User not found'; end if;
  perform public.remove_friend(other);
  insert into public.blocks (blocker, blocked) values (auth.uid(), other) on conflict do nothing;
end;
$$;

create or replace function public.unblock_user(other uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.blocks where blocker = auth.uid() and blocked = other;
$$;

grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;

-- ---------- DMs now need a friendship ----------
create or replace function public.get_or_create_dm(other uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  k text;
  cid uuid;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if other is null or other = me then raise exception 'Pick someone else to chat with'; end if;
  if not exists (select 1 from public.profiles where id = other) then
    raise exception 'User not found';
  end if;

  k := least(me::text, other::text) || ':' || greatest(me::text, other::text);
  select id into cid from public.channels where dm_key = k;
  if cid is not null then
    -- An existing chat can always be reopened (sending is still blocked if needed).
    return cid;
  end if;

  if not public.are_friends(me, other) then
    raise exception 'You can only start chats with friends';
  end if;

  insert into public.channels (kind, dm_key, created_by)
    values ('dm', k, me)
    on conflict (dm_key) do nothing
    returning id into cid;
  if cid is null then
    select id into cid from public.channels where dm_key = k;
  else
    insert into public.channel_members (channel_id, user_id) values (cid, me), (cid, other);
  end if;
  return cid;
end;
$$;

-- No messages across a block.
alter policy "send messages as yourself" on public.messages
  with check (
    author_id = auth.uid()
    and public.can_access_channel(channel_id)
    and not public.dm_blocked(channel_id)
  );
