-- ============================================================
-- Yapper · Stage 10 · Servers
-- Servers with text channels, invite links, roles and permissions.
--   owner            -> can do everything
--   "Manage server"  -> channels, roles, server name/icon, kick
--   "Manage messages"-> delete anyone's messages (moderators)
--   everyone else    -> chat
-- ============================================================

create table public.servers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  icon_path text,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.server_members (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (server_id, user_id)
);
create index server_members_user_idx on public.server_members (user_id);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 32),
  color text check (color is null or color ~ '^#[0-9a-fA-F]{6}$'),
  position int not null default 0,
  manage_server boolean not null default false,
  manage_messages boolean not null default false,
  created_at timestamptz not null default now(),
  unique (id, server_id)
);

create table public.member_roles (
  server_id uuid not null,
  user_id uuid not null,
  role_id uuid not null,
  primary key (user_id, role_id),
  foreign key (server_id, user_id) references public.server_members (server_id, user_id) on delete cascade,
  foreign key (role_id, server_id) references public.roles (id, server_id) on delete cascade
);

create table public.invites (
  code text primary key check (code ~ '^[A-Za-z0-9]{6,16}$'),
  server_id uuid not null references public.servers (id) on delete cascade,
  created_by uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  uses int not null default 0
);

-- Server channels live in the same channels table as DMs and groups.
alter table public.channels
  add column server_id uuid references public.servers (id) on delete cascade,
  add column position int not null default 0;
alter table public.channels drop constraint channels_kind_check;
alter table public.channels add constraint channels_kind_check check (
  (server_id is null and kind in ('dm', 'group')) or (server_id is not null and kind in ('text'))
);
create index channels_server_idx on public.channels (server_id);
-- Only DMs have a dm_key.
alter table public.channels add constraint channels_dm_key_check check ((kind = 'dm') = (dm_key is not null));

-- ---------- Permission helpers ----------
create or replace function public.is_server_member(sid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.server_members where server_id = sid and user_id = auth.uid());
$$;

create or replace function public.server_perm(sid uuid, perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (
      select 1
      from public.member_roles mr
      join public.roles r on r.id = mr.role_id
      where mr.server_id = sid and mr.user_id = auth.uid()
        and (r.manage_server or (perm = 'manage_messages' and r.manage_messages))
    );
$$;

-- Now servers count too: anyone in the server can use its channels.
create or replace function public.can_access_channel(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_channel_member(cid)
    or exists (
      select 1 from public.channels c
      where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
    );
$$;

-- ---------- Row level security ----------
alter table public.servers enable row level security;
alter table public.server_members enable row level security;
alter table public.roles enable row level security;
alter table public.member_roles enable row level security;
alter table public.invites enable row level security;

create policy "see servers you're in" on public.servers for select to authenticated
  using (public.is_server_member(id));
create policy "see members of your servers" on public.server_members for select to authenticated
  using (public.is_server_member(server_id));
create policy "see roles in your servers" on public.roles for select to authenticated
  using (public.is_server_member(server_id));
create policy "see role assignments in your servers" on public.member_roles for select to authenticated
  using (public.is_server_member(server_id));
create policy "see invites to your servers" on public.invites for select to authenticated
  using (public.is_server_member(server_id));

-- Roles: managed by people with "Manage server".
create policy "managers create roles" on public.roles for insert to authenticated
  with check (public.server_perm(server_id, 'manage_server'));
create policy "managers edit roles" on public.roles for update to authenticated
  using (public.server_perm(server_id, 'manage_server'))
  with check (public.server_perm(server_id, 'manage_server'));
create policy "managers delete roles" on public.roles for delete to authenticated
  using (public.server_perm(server_id, 'manage_server'));

create policy "managers assign roles" on public.member_roles for insert to authenticated
  with check (public.server_perm(server_id, 'manage_server'));
create policy "managers unassign roles" on public.member_roles for delete to authenticated
  using (public.server_perm(server_id, 'manage_server'));

-- Server channels: managers rename and delete them (creating goes through create_channel()).
create policy "managers edit channels" on public.channels for update to authenticated
  using (server_id is not null and public.server_perm(server_id, 'manage_server'))
  with check (server_id is not null and public.server_perm(server_id, 'manage_server'));
create policy "managers delete channels" on public.channels for delete to authenticated
  using (server_id is not null and public.server_perm(server_id, 'manage_server'));

-- A channel can't be moved to another server or turned into something else.
create or replace function public.channel_guard()
returns trigger
language plpgsql
as $$
begin
  new.id := old.id;
  new.server_id := old.server_id;
  new.kind := old.kind;
  new.dm_key := old.dm_key;
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  if new.server_id is not null and (new.name is null or char_length(btrim(new.name)) = 0) then
    raise exception 'Channels need a name';
  end if;
  return new;
end;
$$;
create trigger channels_guard before update on public.channels
  for each row execute function public.channel_guard();

-- Invites: any member can make one; the creator or a manager can delete it.
create policy "members create invites" on public.invites for insert to authenticated
  with check (created_by = auth.uid() and public.is_server_member(server_id));
create policy "delete invites" on public.invites for delete to authenticated
  using (created_by = auth.uid() or public.server_perm(server_id, 'manage_server'));

-- Moderators can delete anyone's messages in their server.
create policy "moderators delete messages" on public.messages for delete to authenticated
  using (exists (
    select 1 from public.channels c
    where c.id = channel_id and c.server_id is not null and public.server_perm(c.server_id, 'manage_messages')
  ));

-- ---------- Server functions ----------
create or replace function public.slugify_channel(n text)
returns text
language sql
immutable
as $$
  select left(nullif(regexp_replace(regexp_replace(lower(btrim(n)), '\s+', '-', 'g'), '[^a-z0-9_-]', '', 'g'), ''), 100);
$$;

create or replace function public.create_server(server_name text, server_icon text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  sid uuid;
begin
  if me is null then raise exception 'Not signed in'; end if;
  perform public.check_icon_path(server_icon);
  if (select count(*) from public.servers where owner_id = me) >= 50 then
    raise exception 'You own a lot of servers already';
  end if;
  insert into public.servers (name, icon_path, owner_id) values (btrim(server_name), server_icon, me) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0);
  return sid;
end;
$$;

create or replace function public.update_server(sid uuid, server_name text, server_icon text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if server_icon is distinct from (select icon_path from public.servers where id = sid) then
    perform public.check_icon_path(server_icon);
  end if;
  update public.servers set name = btrim(server_name), icon_path = server_icon where id = sid;
end;
$$;

create or replace function public.delete_server(sid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    raise exception 'Only the owner can delete a server';
  end if;
  delete from public.servers where id = sid;
end;
$$;

create or replace function public.create_channel(sid uuid, channel_name text, channel_kind text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  slug text := public.slugify_channel(channel_name);
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage channels here'; end if;
  if slug is null then raise exception 'Channels need a name'; end if;
  if (select count(*) from public.channels where server_id = sid) >= 100 then raise exception 'Too many channels'; end if;
  insert into public.channels (kind, name, server_id, created_by, position)
    values (coalesce(channel_kind, 'text'), slug, sid, auth.uid(),
            coalesce((select max(position) + 1 from public.channels where server_id = sid), 0))
    returning id into cid;
  return cid;
end;
$$;

create or replace function public.leave_server(sid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    raise exception 'You own this server — delete it instead';
  end if;
  delete from public.server_members where server_id = sid and user_id = auth.uid();
  delete from public.channel_reads r using public.channels c
    where r.channel_id = c.id and c.server_id = sid and r.user_id = auth.uid();
end;
$$;

create or replace function public.kick_member(sid uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t kick people here'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then
    raise exception 'You can''t kick the owner';
  end if;
  delete from public.server_members where server_id = sid and user_id = target;
end;
$$;

-- What someone sees on an invite link before joining.
create or replace function public.get_invite(invite_code text)
returns table (server_id uuid, name text, icon_path text, member_count int, already_member boolean)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.name, s.icon_path,
         (select count(*)::int from public.server_members m where m.server_id = s.id),
         public.is_server_member(s.id)
  from public.invites i
  join public.servers s on s.id = i.server_id
  where i.code = invite_code;
$$;

create or replace function public.join_server(invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select server_id into sid from public.invites where code = invite_code;
  if sid is null then raise exception 'This invite is invalid or has expired'; end if;
  if (select count(*) from public.server_members where user_id = auth.uid()) >= 100 then
    raise exception 'You''re in too many servers';
  end if;
  insert into public.server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  if found then
    update public.invites set uses = uses + 1 where code = invite_code;
  end if;
  return sid;
end;
$$;

grant execute on function public.create_server(text, text) to authenticated;
grant execute on function public.update_server(uuid, text, text) to authenticated;
grant execute on function public.delete_server(uuid) to authenticated;
grant execute on function public.create_channel(uuid, text, text) to authenticated;
grant execute on function public.leave_server(uuid) to authenticated;
grant execute on function public.kick_member(uuid, uuid) to authenticated;
grant execute on function public.get_invite(text) to anon, authenticated;
grant execute on function public.join_server(text) to authenticated;

-- ---------- Unread counts now include server channels ----------
create or replace function public.unread_counts()
returns table (channel_id uuid, unread int, muted boolean)
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select cm.channel_id, cm.joined_at as since from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at from public.channels c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text'
  )
  select
    mine.channel_id,
    (
      select count(*)::int from (
        select 1 from public.messages m
        where m.channel_id = mine.channel_id
          and m.author_id <> auth.uid()
          and m.created_at > coalesce(r.last_read_at, mine.since)
        limit 100
      ) x
    ),
    coalesce(r.muted, false)
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid();
$$;

alter publication supabase_realtime add table public.servers;
alter publication supabase_realtime add table public.server_members;
alter publication supabase_realtime add table public.roles;
alter publication supabase_realtime add table public.member_roles;
