-- ============================================================
-- Yapper · Stage 3 · Custom emojis
-- Upload your own (animated ones too). Anyone in a chat with you
-- can use your emojis there.
-- ============================================================

create table public.emojis (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (name ~ '^[A-Za-z0-9_]{2,32}$'),
  path text not null,
  animated boolean not null default false,
  created_at timestamptz not null default now(),
  constraint emojis_path_check check (path like owner_id::text || '/%')
);
create unique index emojis_owner_name_idx on public.emojis (owner_id, lower(name));
create index emojis_owner_idx on public.emojis (owner_id);

-- Keep it reasonable: 100 custom emojis per person.
create or replace function public.emoji_limit()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.emojis where owner_id = new.owner_id) >= 100 then
    raise exception 'You can have up to 100 custom emojis';
  end if;
  return new;
end;
$$;
create trigger emojis_limit before insert on public.emojis
  for each row execute function public.emoji_limit();

alter table public.emojis enable row level security;
create policy "emojis are visible to signed-in users"
  on public.emojis for select to authenticated using (true);
create policy "add your own emojis"
  on public.emojis for insert to authenticated with check (owner_id = auth.uid());
create policy "rename your own emojis"
  on public.emojis for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "delete your own emojis"
  on public.emojis for delete to authenticated using (owner_id = auth.uid());

alter publication supabase_realtime add table public.emojis;

-- ---------- Storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('emojis', 'emojis', true, 1048576, array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do nothing;

create policy "emoji images: read own folder"
  on storage.objects for select to authenticated
  using (bucket_id = 'emojis' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "emoji images: upload to own folder"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'emojis' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "emoji images: delete own folder"
  on storage.objects for delete to authenticated
  using (bucket_id = 'emojis' and (storage.foldername(name))[1] = auth.uid()::text);
