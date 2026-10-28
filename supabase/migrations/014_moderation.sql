-- ============================================================
-- Yapper · Running a big server
--   * Read-only channels (e.g. #announcements): everyone can read and react,
--     only chosen roles (plus the owner and server managers) can post.
--   * Slowmode: one message every N seconds per person (moderators exempt).
--   * Bans: banned people are removed and can't rejoin with any invite.
-- ============================================================

alter table public.channels
  add column read_only boolean not null default false,
  add column slowmode int not null default 0 check (slowmode between 0 and 21600);

create table public.channel_post_roles (
  channel_id uuid not null references public.channels (id) on delete cascade,
  role_id uuid not null references public.roles (id) on delete cascade,
  server_id uuid not null references public.servers (id) on delete cascade,
  primary key (channel_id, role_id)
);
create index channel_post_roles_server_idx on public.channel_post_roles (server_id);
alter table public.channel_post_roles enable row level security;
create policy "see who can post in your servers" on public.channel_post_roles for select to authenticated
  using (public.is_server_member(server_id));
alter publication supabase_realtime add table public.channel_post_roles;

-- Can I post in this channel? Always for DMs/groups and normal channels.
create or replace function public.can_post_channel(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select
      not c.read_only
      or public.server_perm(c.server_id, 'manage_server')
      or exists (
        select 1 from public.channel_post_roles cr
        join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
        where cr.channel_id = c.id
      )
    from public.channels c where c.id = cid
  ), true);
$$;

alter policy "send messages as yourself" on public.messages
  with check (
    author_id = auth.uid()
    and public.can_access_channel(channel_id)
    and not public.dm_blocked(channel_id)
    and public.can_post_channel(channel_id)
  );

-- Slowmode, checked by the database so it can't be skipped.
create index messages_channel_author_idx on public.messages (channel_id, author_id, created_at desc);

create or replace function public.message_slowmode()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.channels;
  last_at timestamptz;
  wait int;
begin
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null or c.slowmode <= 0 then return new; end if;
  if public.server_perm(c.server_id, 'manage_messages') then return new; end if;
  select max(created_at) into last_at from public.messages
    where channel_id = new.channel_id and author_id = new.author_id;
  if last_at is not null and last_at > now() - make_interval(secs => c.slowmode) then
    wait := ceil(extract(epoch from (last_at + make_interval(secs => c.slowmode) - now())));
    raise exception 'Slowmode is on — you can send another message in %s', wait || 's'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger messages_slowmode before insert on public.messages
  for each row execute function public.message_slowmode();

-- Channel settings in one go (managers only).
create or replace function public.set_channel_posting(cid uuid, make_read_only boolean, post_role_ids uuid[], slow int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
begin
  select server_id into sid from public.channels where id = cid;
  if sid is null or not public.server_perm(sid, 'manage_server') then
    raise exception 'You can''t manage this channel';
  end if;
  update public.channels
    set read_only = coalesce(make_read_only, false), slowmode = greatest(0, least(coalesce(slow, 0), 21600))
    where id = cid;
  delete from public.channel_post_roles where channel_id = cid;
  if make_read_only then
    insert into public.channel_post_roles (channel_id, role_id, server_id)
      select cid, r.id, sid from public.roles r
      where r.server_id = sid and r.id = any(coalesce(post_role_ids, '{}'));
  end if;
  update public.servers set name = name where id = sid; -- nudge everyone's app to refresh
end;
$$;
grant execute on function public.set_channel_posting(uuid, boolean, uuid[], int) to authenticated;

-- ---------- Bans ----------
create table public.server_bans (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  banned_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (server_id, user_id)
);
alter table public.server_bans enable row level security;
create policy "managers see bans" on public.server_bans for select to authenticated
  using (public.server_perm(server_id, 'manage_server'));

create or replace function public.ban_member(sid uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t ban people here'; end if;
  if target = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then
    raise exception 'You can''t ban the owner';
  end if;
  insert into public.server_bans (server_id, user_id, banned_by) values (sid, target, auth.uid())
    on conflict do nothing;
  delete from public.server_members where server_id = sid and user_id = target;
  delete from public.invites where server_id = sid and created_by = target;
end;
$$;

create or replace function public.unban_member(sid uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage bans here'; end if;
  delete from public.server_bans where server_id = sid and user_id = target;
end;
$$;
grant execute on function public.ban_member(uuid, uuid) to authenticated;
grant execute on function public.unban_member(uuid, uuid) to authenticated;

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
  if exists (select 1 from public.server_bans where server_id = sid and user_id = auth.uid()) then
    raise exception 'You''re banned from this server';
  end if;
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
