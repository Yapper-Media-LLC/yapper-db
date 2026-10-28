-- Soundboard: short clips per server, played to everyone in a voice channel (flag: soundboard).
create table if not exists public.sounds (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers (id) on delete cascade,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 32),
  emoji text not null default '🔊' check (char_length(emoji) <= 16),
  path text not null,
  volume numeric not null default 1 check (volume between 0 and 1),
  created_at timestamptz not null default now(),
  constraint sounds_path_check check (path like owner_id::text || '/%')
);
create index if not exists sounds_server_idx on public.sounds (server_id);
alter table public.sounds enable row level security;
create policy "members see sounds" on public.sounds for select to authenticated using (public.is_server_member(server_id));
create policy "managers add sounds" on public.sounds for insert to authenticated
  with check (owner_id = auth.uid() and public.server_perm(server_id, 'manage_emojis') and (select count(*) from public.sounds s where s.server_id = sounds.server_id) < 24);
create policy "managers remove sounds" on public.sounds for delete to authenticated using (public.server_perm(server_id, 'manage_emojis'));
alter publication supabase_realtime add table public.sounds;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sounds', 'sounds', true, 524288, array['audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/mp4', 'audio/webm', 'audio/x-m4a'])
on conflict (id) do nothing;
create policy "sounds: read" on storage.objects for select to authenticated using (bucket_id = 'sounds');
create policy "sounds: upload own folder" on storage.objects for insert to authenticated with check (bucket_id = 'sounds' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "sounds: delete own folder" on storage.objects for delete to authenticated using (bucket_id = 'sounds' and (storage.foldername(name))[1] = auth.uid()::text);
insert into public.feature_flags (key, label, description, mode) values ('soundboard', 'Soundboard', 'Play short sound clips in voice channels', 'off') on conflict (key) do nothing;
