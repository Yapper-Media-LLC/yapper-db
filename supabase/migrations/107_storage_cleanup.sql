-- Originals still in Supabase Storage whose copy is on R2 (so they can be deleted).
create or replace function public.admin_storage_migrated(b text, lim integer default 200)
returns table(name text, bytes bigint)
language sql stable security definer set search_path to 'public' as $$
  select o.name, m.bytes
  from storage.objects o
  join public.media_migrated m on m.bucket = b and m.path = o.name
  where o.bucket_id = b
  order by o.created_at
  limit least(coalesce(lim, 200), 300);
$$;
revoke all on function public.admin_storage_migrated(text, integer) from public, anon, authenticated;

create or replace function public.admin_storage_left()
returns table(bucket text, total bigint, bytes bigint)
language sql stable security definer set search_path to 'public' as $$
  select o.bucket_id, count(*), coalesce(sum((o.metadata->>'size')::bigint), 0)
  from storage.objects o
  where o.bucket_id in ('attachments', 'avatars', 'banners', 'icons', 'emojis')
  group by o.bucket_id;
$$;
revoke all on function public.admin_storage_left() from public, anon, authenticated;
