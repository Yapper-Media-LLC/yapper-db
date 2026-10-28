-- Channel categories (like Discord): collapsible groups of channels in a server. Flag: categories.
create table if not exists public.channel_categories (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  position int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists channel_categories_server_idx on public.channel_categories (server_id, position);
alter table public.channel_categories enable row level security;
create policy "see categories of your servers" on public.channel_categories for select to authenticated
  using (server_id in (select public.my_server_ids()));
grant select on public.channel_categories to authenticated;

alter table public.channels add column if not exists category_id uuid references public.channel_categories(id) on delete set null;
create index if not exists channels_category_idx on public.channels (category_id);

create or replace function public.create_category(sid uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; n text := btrim(coalesce(p_name, ''));
begin
  if not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  if char_length(n) not between 1 and 40 then raise exception 'Category names are 1 to 40 characters'; end if;
  if (select count(*) from public.channel_categories where server_id = sid) >= 50 then raise exception 'Up to 50 categories'; end if;
  insert into public.channel_categories (server_id, name, position)
    values (sid, n, coalesce((select max(position) + 1 from public.channel_categories where server_id = sid), 0))
    returning id into cid;
  return cid;
end; $$;

create or replace function public.rename_category(cid uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; n text := btrim(coalesce(p_name, ''));
begin
  select server_id into sid from public.channel_categories where id = cid;
  if sid is null or not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  if char_length(n) not between 1 and 40 then raise exception 'Category names are 1 to 40 characters'; end if;
  update public.channel_categories set name = n where id = cid;
end; $$;

-- Removing a category keeps its channels (category_id goes null, they're back at the top).
create policy "managers remove categories" on public.channel_categories for delete to authenticated
  using (public.server_perm(server_id, 'manage_channels'));
grant delete on public.channel_categories to authenticated;

create or replace function public.reorder_categories(sid uuid, ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  for i in 1 .. coalesce(array_length(ids, 1), 0) loop
    update public.channel_categories set position = i - 1 where id = ids[i] and server_id = sid;
  end loop;
end; $$;

-- Move a channel into a category (null = none) and, optionally, give the full channel order at the same time.
create or replace function public.set_channel_category(chid uuid, cid uuid, ids uuid[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; i int;
begin
  select server_id into sid from public.channels where id = chid;
  if sid is null or not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  if cid is not null and not exists (select 1 from public.channel_categories where id = cid and server_id = sid) then raise exception 'No such category'; end if;
  update public.channels set category_id = cid where id = chid;
  for i in 1 .. coalesce(array_length(ids, 1), 0) loop
    update public.channels set position = i - 1 where id = ids[i] and server_id = sid;
  end loop;
end; $$;

revoke all on function public.create_category(uuid, text), public.rename_category(uuid, text),
  public.reorder_categories(uuid, uuid[]), public.set_channel_category(uuid, uuid, uuid[]) from public, anon;
grant execute on function public.create_category(uuid, text), public.rename_category(uuid, text),
  public.reorder_categories(uuid, uuid[]), public.set_channel_category(uuid, uuid, uuid[]) to authenticated;

-- Live: category changes go to the server topic like channel changes do.
create or replace function public.bc_category()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.broadcast_changes('server:' || coalesce(new.server_id, old.server_id), 'server', tg_op, tg_table_name, tg_table_schema, new, old);
  return null;
end; $$;
create or replace trigger channel_categories_bc after insert or update or delete on public.channel_categories
  for each row execute function public.bc_category();

insert into public.feature_flags (key, label, description, mode) values
  ('categories', 'Channel categories', 'Group channels under collapsible headings', 'off') on conflict (key) do nothing;
