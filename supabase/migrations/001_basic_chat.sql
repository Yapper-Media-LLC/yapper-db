-- ============================================================
-- Yapper · Stage 1 · Basic chat
-- Profiles, direct-message channels and messages.
-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run.
-- ============================================================

-- ---------- Profiles ----------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_.]{2,32}$'),
  created_at timestamptz not null default now()
);
create unique index profiles_username_lower_idx on public.profiles (lower(username));

-- Create a profile automatically whenever someone signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base text;
  candidate text;
  n int := 0;
begin
  base := regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', ''), '[^A-Za-z0-9_.]', '', 'g');
  if length(base) < 2 then
    base := regexp_replace(split_part(coalesce(new.email, ''), '@', 1), '[^A-Za-z0-9_.]', '', 'g');
  end if;
  if length(base) < 2 then
    base := 'yapper';
  end if;
  base := left(base, 28);
  candidate := base;
  while exists (select 1 from public.profiles where lower(username) = lower(candidate)) loop
    n := n + 1;
    candidate := base || n::text;
  end loop;
  insert into public.profiles (id, username) values (new.id, candidate);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Lets the sign-up form check a username before the account exists.
create or replace function public.username_taken(name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where lower(username) = lower(name));
$$;
grant execute on function public.username_taken(text) to anon, authenticated;

-- ---------- Channels (a conversation of any kind) ----------
create table public.channels (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  name text,
  dm_key text unique,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  constraint channels_kind_check check (kind in ('dm'))
);

create table public.channel_members (
  channel_id uuid not null references public.channels (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (channel_id, user_id)
);
create index channel_members_user_idx on public.channel_members (user_id);

-- ---------- Messages ----------
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  content text not null default '',
  created_at timestamptz not null default now(),
  constraint messages_content_check check (char_length(content) between 1 and 4000)
);
create index messages_channel_created_idx on public.messages (channel_id, created_at desc);

-- Keep channels sorted by most recent activity.
create or replace function public.touch_channel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.channels set last_message_at = new.created_at where id = new.channel_id;
  return new;
end;
$$;
create trigger messages_touch_channel
  after insert on public.messages
  for each row execute function public.touch_channel();

-- Messages can never be backdated or attributed to someone else.
create or replace function public.message_defaults()
returns trigger
language plpgsql
as $$
begin
  new.created_at := now();
  return new;
end;
$$;
create trigger messages_defaults
  before insert on public.messages
  for each row execute function public.message_defaults();

-- ---------- Access helpers ----------
create or replace function public.is_channel_member(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.channel_members
    where channel_id = cid and user_id = auth.uid()
  );
$$;

-- Who can read and write in a channel. Replaced in later stages
-- (servers add their own rules).
create or replace function public.can_access_channel(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_channel_member(cid);
$$;

-- Start (or reopen) a direct message with someone.
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
  if cid is null then
    insert into public.channels (kind, dm_key, created_by)
      values ('dm', k, me)
      on conflict (dm_key) do nothing
      returning id into cid;
    if cid is null then
      select id into cid from public.channels where dm_key = k;
    else
      insert into public.channel_members (channel_id, user_id)
        values (cid, me), (cid, other);
    end if;
  end if;
  return cid;
end;
$$;
grant execute on function public.get_or_create_dm(uuid) to authenticated;

-- ---------- Row level security ----------
alter table public.profiles enable row level security;
alter table public.channels enable row level security;
alter table public.channel_members enable row level security;
alter table public.messages enable row level security;

create policy "profiles are visible to signed-in users"
  on public.profiles for select to authenticated using (true);
create policy "you can edit your own profile"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "see channels you can access"
  on public.channels for select to authenticated
  using (public.can_access_channel(id));

create policy "see members of channels you can access"
  on public.channel_members for select to authenticated
  using (public.can_access_channel(channel_id));

create policy "read messages in channels you can access"
  on public.messages for select to authenticated
  using (public.can_access_channel(channel_id));
create policy "send messages as yourself"
  on public.messages for insert to authenticated
  with check (author_id = auth.uid() and public.can_access_channel(channel_id));

-- ---------- Live updates ----------
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.channel_members;
