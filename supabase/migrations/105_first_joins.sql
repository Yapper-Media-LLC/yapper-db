-- Leaving and rejoining a server kept resetting joined_at, which silently took away "joined before X"
-- roles (OG). The first join is remembered per server and put back on rejoin. Applied live Oct 15.

create table if not exists public.server_first_joins (
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null,
  first_joined_at timestamptz not null default now(),
  primary key (server_id, user_id)
);
alter table public.server_first_joins enable row level security;

create or replace function public.keep_first_join() returns trigger
language plpgsql security definer set search_path = public as $$
declare first timestamptz;
begin
  insert into public.server_first_joins (server_id, user_id, first_joined_at) values (new.server_id, new.user_id, coalesce(new.joined_at, now()))
    on conflict (server_id, user_id) do nothing;
  select first_joined_at into first from public.server_first_joins where server_id = new.server_id and user_id = new.user_id;
  if first is not null and first < coalesce(new.joined_at, now()) then new.joined_at := first; end if;
  return new;
end; $$;
create or replace trigger server_members_first_join before insert on public.server_members for each row execute function public.keep_first_join();

-- Backfill from current members and their earliest message in the server.
insert into public.server_first_joins (server_id, user_id, first_joined_at)
  select m.server_id, m.user_id, least(m.joined_at, coalesce((select min(x.created_at) from public.messages x join public.channels c on c.id = x.channel_id where c.server_id = m.server_id and x.author_id = m.user_id), m.joined_at))
  from public.server_members m
  on conflict (server_id, user_id) do update set first_joined_at = least(server_first_joins.first_joined_at, excluded.first_joined_at);
update public.server_members m set joined_at = f.first_joined_at from public.server_first_joins f
  where f.server_id = m.server_id and f.user_id = m.user_id and f.first_joined_at < m.joined_at;
