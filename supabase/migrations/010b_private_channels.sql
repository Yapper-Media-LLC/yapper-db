-- ============================================================
-- Yapper · Stage 10 (extra) · Private channels
-- A server channel can be limited to certain roles. People without
-- one of those roles can't see it, read it, post in it or join its
-- voice call. The owner and "Manage server" roles always can.
-- ============================================================

alter table public.channels add column private boolean not null default false;

create table public.channel_roles (
  channel_id uuid not null references public.channels (id) on delete cascade,
  role_id uuid not null references public.roles (id) on delete cascade,
  server_id uuid not null references public.servers (id) on delete cascade,
  primary key (channel_id, role_id)
);
create index channel_roles_server_idx on public.channel_roles (server_id);

alter table public.channel_roles enable row level security;
-- Everyone in the server can see which roles a channel is for; changes go through set_channel_access().
create policy "see channel roles in your servers" on public.channel_roles for select to authenticated
  using (public.is_server_member(server_id));

alter publication supabase_realtime add table public.channel_roles;

-- Can I use this channel? DMs/groups: if I'm in it. Server channels: if I'm in
-- the server and the channel is public, or I manage the server, or I have one of its roles.
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
        and (
          not c.private
          or public.server_perm(c.server_id, 'manage_server')
          or exists (
            select 1 from public.channel_roles cr
            join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
            where cr.channel_id = c.id
          )
        )
    );
$$;

create or replace function public.set_channel_access(cid uuid, make_private boolean, role_ids uuid[])
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
  update public.channels set private = coalesce(make_private, false) where id = cid;
  delete from public.channel_roles where channel_id = cid;
  if make_private then
    insert into public.channel_roles (channel_id, role_id, server_id)
      select cid, r.id, sid from public.roles r
      where r.server_id = sid and r.id = any(coalesce(role_ids, '{}'));
  end if;
  -- Nudge everyone in the server to refresh what they can see (people who just
  -- lost access don't get the channel's own update, since they can't see it any more).
  update public.servers set name = name where id = sid;
end;
$$;
grant execute on function public.set_channel_access(uuid, boolean, uuid[]) to authenticated;

-- Unread badges only for channels you can actually open.
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
    where c.kind = 'text' and public.can_access_channel(c.id)
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
