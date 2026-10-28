-- ============================================================
-- Yapper · Feature flags + batch 1 (applied to production 2026-10-13)
-- Flags: off / test (listed servers only) / everyone, switched in Admin → Features.
-- Batch 1 behind flags: nicknames, pins, search, channel reorder, links.
-- ============================================================

create table if not exists public.feature_flags (
  key text primary key,
  label text not null,
  description text not null default '',
  mode text not null default 'off' check (mode in ('off', 'test', 'everyone')),
  servers uuid[] not null default '{}',
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);
alter table public.feature_flags enable row level security;
drop policy if exists "everyone reads flags" on public.feature_flags;
create policy "everyone reads flags" on public.feature_flags for select to authenticated using (true);
drop policy if exists "admins change flags" on public.feature_flags;
create policy "admins change flags" on public.feature_flags for update to authenticated using (public.is_site_admin()) with check (public.is_site_admin());
alter publication supabase_realtime add table public.feature_flags;

create or replace function public.feature_on(k text, sid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and sid is not null and sid = any(servers)) from public.feature_flags where key = k), false);
$$;
create or replace function public.feature_on_for_me(k text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers))) from public.feature_flags where key = k), false);
$$;

insert into public.feature_flags (key, label, description, mode) values
  ('typing', 'Typing indicator', '"X is typing…" under the composer', 'off'),
  ('pins', 'Pinned messages', 'Pin messages in a channel; pins panel in the header', 'off'),
  ('search', 'Message search', 'Search messages in a server or chat', 'off'),
  ('nicknames', 'Nicknames', 'Per-server display names', 'off'),
  ('reorder', 'Rearrange channels', 'Move channels up and down in server settings', 'off'),
  ('links', 'Social links', 'Links on profiles and servers', 'off'),
  ('polls', 'Polls', 'Create polls in channels', 'off'),
  ('media', 'Video & audio uploads', 'Send MP4/WebM video and MP3/OGG/WAV audio', 'off'),
  ('gifs', 'GIF picker', 'Search GIFs from the composer (needs a Tenor key on the server)', 'off'),
  ('account', 'Account settings', 'Change email and password from Settings', 'off'),
  ('mfa', 'Two-factor authentication', 'Authenticator-app 2FA in Settings', 'off'),
  ('switch', 'Switch accounts', 'Keep several accounts signed in and switch between them', 'off')
on conflict (key) do nothing;

-- Nicknames
alter table public.server_members add column if not exists nickname text check (nickname is null or char_length(nickname) between 1 and 32);
create or replace function public.set_nickname(sid uuid, target uuid, nick text)
returns void language plpgsql security definer set search_path = public as $$
declare n text := nullif(trim(coalesce(nick, '')), '');
begin
  if not public.feature_on('nicknames', sid) then raise exception 'Nicknames aren''t available here yet'; end if;
  if target <> auth.uid() and not public.server_perm(sid, 'manage_messages') then raise exception 'You can''t change other people''s nicknames'; end if;
  if n is not null and (public.bad_name(n) or public.has_adult_link(n)) then raise exception 'That nickname isn''t allowed.'; end if;
  update public.server_members set nickname = n where server_id = sid and user_id = target;
end;
$$;
revoke all on function public.set_nickname(uuid, uuid, text) from public, anon;
grant execute on function public.set_nickname(uuid, uuid, text) to authenticated;

-- Pins
alter table public.messages add column if not exists pinned_at timestamptz;
alter table public.messages add column if not exists pinned_by uuid references public.profiles (id) on delete set null;
create index if not exists messages_pinned_idx on public.messages (channel_id, pinned_at desc) where pinned_at is not null;
create or replace function public.pin_message(mid uuid, pinned boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m public.messages; sid uuid;
begin
  select * into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'Message not found'; end if;
  select server_id into sid from public.channels where id = m.channel_id;
  if not public.feature_on('pins', sid) and not public.feature_on_for_me('pins') then raise exception 'Pins aren''t available here yet'; end if;
  if sid is not null and not public.server_perm(sid, 'manage_messages') then raise exception 'You can''t pin messages here'; end if;
  if pinned and (select count(*) from public.messages where channel_id = m.channel_id and pinned_at is not null) >= 50 then raise exception 'This channel already has 50 pins'; end if;
  update public.messages set pinned_at = case when pinned then now() end, pinned_by = case when pinned then auth.uid() end where id = mid;
end;
$$;
revoke all on function public.pin_message(uuid, boolean) from public, anon;
grant execute on function public.pin_message(uuid, boolean) to authenticated;

-- Search
create index if not exists messages_search_idx on public.messages using gin (to_tsvector('simple', coalesce(content, '')));
create or replace function public.search_messages(q text, sid uuid default null, cid uuid default null)
returns setof public.messages language sql stable security definer set search_path = public as $$
  select m.* from public.messages m
  join public.channels c on c.id = m.channel_id
  where (cid is null or m.channel_id = cid)
    and (sid is null or c.server_id = sid)
    and public.can_access_channel(m.channel_id)
    and (public.feature_on('search', c.server_id) or public.feature_on_for_me('search'))
    and to_tsvector('simple', coalesce(m.content, '')) @@ websearch_to_tsquery('simple', q)
  order by m.created_at desc
  limit 50;
$$;
revoke all on function public.search_messages(text, uuid, uuid) from public, anon;
grant execute on function public.search_messages(text, uuid, uuid) to authenticated;

-- Rearrange channels
create or replace function public.reorder_channels(sid uuid, ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t rearrange channels here'; end if;
  if not public.feature_on('reorder', sid) then raise exception 'Rearranging isn''t available here yet'; end if;
  for i in 1 .. coalesce(array_length(ids, 1), 0) loop
    update public.channels set position = i - 1 where id = ids[i] and server_id = sid;
  end loop;
end;
$$;
revoke all on function public.reorder_channels(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_channels(uuid, uuid[]) to authenticated;

-- Links
alter table public.profiles add column if not exists links jsonb not null default '[]'::jsonb;
alter table public.servers add column if not exists links jsonb not null default '[]'::jsonb;
create or replace function public.check_links()
returns trigger language plpgsql as $$
declare l jsonb; u text;
begin
  if jsonb_typeof(new.links) <> 'array' or jsonb_array_length(new.links) > 5 then raise exception 'Up to 5 links' using errcode = 'check_violation'; end if;
  for l in select * from jsonb_array_elements(new.links) loop
    u := l ->> 'url';
    if u is null or u !~* '^https?://[^\s]{3,200}$' then raise exception 'Links must start with http(s)://' using errcode = 'check_violation'; end if;
    if public.has_adult_link(u) then raise exception 'Links to adult sites aren''t allowed on Yapper.' using errcode = 'check_violation'; end if;
    if char_length(coalesce(l ->> 'label', '')) > 40 then raise exception 'Link labels are up to 40 characters' using errcode = 'check_violation'; end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists profiles_check_links on public.profiles;
create trigger profiles_check_links before insert or update of links on public.profiles for each row execute function public.check_links();
drop trigger if exists servers_check_links on public.servers;
create trigger servers_check_links before insert or update of links on public.servers for each row execute function public.check_links();
