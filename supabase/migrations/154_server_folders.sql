-- 154: server folders in the rail (flag `server_folders`) and the collapsing server banner (flag `banner_collapse`).
-- The banner needs no SQL, only its flag row. Re-runnable.

set lock_timeout = '5s';

-- ---------- Server folders ----------
-- One row per account: the folders of its server rail. The order of the rail itself stays in
-- profiles.server_order (a folder sits where its servers are in that order).
-- folders = [{"id": "f1a2b3c4", "name": "Games" | null, "color": "#rrggbb" | null, "servers": ["<uuid>", ...]}, ...]
-- Only the owner can read or write it. The app reads it with one primary-key lookup when the rail
-- mounts (flagged users only), never from bootstrap.

-- Shape check, used by the table's check constraint so every write path is covered:
-- at most 50 folders, names up to 32 characters, #rrggbb colours, 1..100 server ids per folder,
-- no server in two folders, unique folder ids, 64 KB at most.
create or replace function public.server_folders_ok(f jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare
  e jsonb;
  s jsonb;
begin
  if f is null or jsonb_typeof(f) <> 'array' then return false; end if;
  if jsonb_array_length(f) > 50 then return false; end if;
  if octet_length(f::text) > 65536 then return false; end if;
  for e in select value from jsonb_array_elements(f) loop
    if jsonb_typeof(e) <> 'object' then return false; end if;
    if (e - array['id', 'name', 'color', 'servers']) <> '{}'::jsonb then return false; end if;
    if jsonb_typeof(e->'id') is distinct from 'string' or (e->>'id') !~ '^[A-Za-z0-9_-]{1,24}$' then return false; end if;
    if e ? 'name' and jsonb_typeof(e->'name') <> 'null' then
      if jsonb_typeof(e->'name') <> 'string' or char_length(e->>'name') > 32 then return false; end if;
    end if;
    if e ? 'color' and jsonb_typeof(e->'color') <> 'null' then
      if jsonb_typeof(e->'color') <> 'string' or (e->>'color') !~ '^#[0-9a-f]{6}$' then return false; end if;
    end if;
    if jsonb_typeof(e->'servers') is distinct from 'array' then return false; end if;
    if jsonb_array_length(e->'servers') not between 1 and 100 then return false; end if;
    for s in select value from jsonb_array_elements(e->'servers') loop
      if jsonb_typeof(s) <> 'string' or (s #>> '{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
    end loop;
  end loop;
  -- Duplicates checked once at the end (linear, not a growing array per element).
  if (select count(*) <> count(distinct e2->>'id') from jsonb_array_elements(f) e2) then return false; end if;
  if (select count(*) <> count(distinct v) from jsonb_array_elements(f) e2, jsonb_array_elements_text(e2->'servers') v) then return false; end if;
  return true;
end; $$;
revoke all on function public.server_folders_ok(jsonb) from public, anon;
grant execute on function public.server_folders_ok(jsonb) to authenticated;

create table if not exists public.user_server_folders (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  folders jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'user_server_folders_shape' and conrelid = 'public.user_server_folders'::regclass) then
    alter table public.user_server_folders add constraint user_server_folders_shape check (public.server_folders_ok(folders));
  end if;
end $$;

alter table public.user_server_folders enable row level security;
revoke all on public.user_server_folders from public, anon, authenticated;
grant select, insert, update on public.user_server_folders to authenticated;

-- Read your own row; write it only while the feature is on for you (test users first).
-- (Created only if missing, so the file is re-runnable and goes through the Supabase MCP as is.)
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_server_folders' and policyname = 'own folders read') then
    create policy "own folders read" on public.user_server_folders for select to authenticated
      using ((select auth.uid()) = user_id);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_server_folders' and policyname = 'own folders insert') then
    create policy "own folders insert" on public.user_server_folders for insert to authenticated
      with check ((select auth.uid()) = user_id and (select public.feature_on_for_me('server_folders')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_server_folders' and policyname = 'own folders update') then
    create policy "own folders update" on public.user_server_folders for update to authenticated
      using ((select auth.uid()) = user_id)
      with check ((select auth.uid()) = user_id and (select public.feature_on_for_me('server_folders')));
  end if;
end $$;

-- updated_at is the server's clock, whatever the client sends.
create or replace function public.user_server_folders_touch()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end; $$;
revoke all on function public.user_server_folders_touch() from public, anon, authenticated;
create or replace trigger user_server_folders_touch before insert or update on public.user_server_folders
  for each row execute function public.user_server_folders_touch();

-- ---------- Flags (test only until Antic says publish) ----------
insert into public.feature_flags (key, label, description, mode, servers) values
  ('server_folders', 'Server folders', 'Drag servers onto each other in the rail to group them into folders, synced to your account', 'test', '{}')
on conflict (key) do nothing;
insert into public.feature_flags (key, label, description, mode, servers) values
  ('banner_collapse', 'Collapsing server banner', 'The server banner shrinks and fades as you scroll the channel list', 'test', '{}')
on conflict (key) do nothing;
