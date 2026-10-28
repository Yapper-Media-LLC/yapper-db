-- ============================================================
-- Yapper · Stage 2 · Profiles
-- Bio, profile picture and banner (GIFs welcome).
-- ============================================================

alter table public.profiles
  add column bio text not null default '' check (char_length(bio) <= 190),
  -- Paths inside our own storage buckets, e.g. "<user id>/1712345.gif".
  -- Only paths in your own folder are allowed, so nobody can point
  -- their picture at some random tracking URL.
  add column avatar_path text,
  add column banner_path text,
  add column banner_x smallint not null default 50 check (banner_x between 0 and 100),
  add column banner_y smallint not null default 50 check (banner_y between 0 and 100),
  add constraint profiles_avatar_path_check check (avatar_path is null or avatar_path like id::text || '/%'),
  add constraint profiles_banner_path_check check (banner_path is null or banner_path like id::text || '/%');

-- Everyone sees profile changes live (new picture, new name).
alter publication supabase_realtime add table public.profiles;

-- ---------- Storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 8388608, array['image/png', 'image/jpeg', 'image/gif', 'image/webp']),
  ('banners', 'banners', true, 10485760, array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do nothing;

-- Upload, replace and delete only inside your own folder.
create policy "profile images: read own folder"
  on storage.objects for select to authenticated
  using (bucket_id in ('avatars', 'banners') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "profile images: upload to own folder"
  on storage.objects for insert to authenticated
  with check (bucket_id in ('avatars', 'banners') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "profile images: update own folder"
  on storage.objects for update to authenticated
  using (bucket_id in ('avatars', 'banners') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "profile images: delete own folder"
  on storage.objects for delete to authenticated
  using (bucket_id in ('avatars', 'banners') and (storage.foldername(name))[1] = auth.uid()::text);
