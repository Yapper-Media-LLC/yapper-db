-- ============================================================
-- Yapper · Server-side image checks
-- The browser already checks images before upload, but anyone talking to the
-- storage API directly skips that. Now the server (/api/media/scan) checks every
-- upload and records a verdict here, and a message, profile, server, group chat
-- or emoji can only reference an image whose verdict is 'ok'.
-- Banning someone queues all their files for deletion (/api/media/purge).
-- ============================================================

create table if not exists public.media_scans (
  bucket text not null,
  path text not null,
  user_id uuid,
  score real not null,
  verdict text not null check (verdict in ('ok', 'blocked')),
  scanned_at timestamptz not null default now(),
  primary key (bucket, path)
);
alter table public.media_scans enable row level security;
create policy "own scans" on public.media_scans for select to authenticated
  using (user_id = auth.uid() or public.is_site_admin());
create index if not exists media_scans_blocked_idx on public.media_scans (user_id, scanned_at) where verdict = 'blocked';

-- Files to delete from Storage. The server works through this; nobody else touches it.
create table if not exists public.media_purge (
  bucket text not null,
  path text not null,
  queued_at timestamptz not null default now(),
  done_at timestamptz,
  error text,
  primary key (bucket, path)
);
alter table public.media_purge enable row level security;

create or replace function public.media_ok(b text, p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.media_scans where bucket = b and path = p and verdict = 'ok');
$$;

-- tg_argv is pairs of (column, bucket). A column that changes to a new, non-null
-- path must point at a checked image.
create or replace function public.require_scanned_media()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  i int;
  col text;
  b text;
  val text;
  old_val text;
begin
  for i in 0 .. (tg_nargs / 2) - 1 loop
    col := tg_argv[i * 2];
    b := tg_argv[i * 2 + 1];
    val := to_jsonb(new) ->> col;
    old_val := case when tg_op = 'UPDATE' then to_jsonb(old) ->> col else null end;
    if val is not null and val is distinct from old_val and not public.media_ok(b, val) then
      raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists messages_scanned_media on public.messages;
create trigger messages_scanned_media before insert or update of attachment_path on public.messages
  for each row execute function public.require_scanned_media('attachment_path', 'attachments');
drop trigger if exists profiles_scanned_media on public.profiles;
create trigger profiles_scanned_media before insert or update of avatar_path, banner_path on public.profiles
  for each row execute function public.require_scanned_media('avatar_path', 'avatars', 'banner_path', 'banners');
drop trigger if exists servers_scanned_media on public.servers;
create trigger servers_scanned_media before insert or update of icon_path on public.servers
  for each row execute function public.require_scanned_media('icon_path', 'icons');
drop trigger if exists channels_scanned_media on public.channels;
create trigger channels_scanned_media before insert or update of icon_path on public.channels
  for each row execute function public.require_scanned_media('icon_path', 'icons');
drop trigger if exists emojis_scanned_media on public.emojis;
create trigger emojis_scanned_media before insert or update of path on public.emojis
  for each row execute function public.require_scanned_media('path', 'emojis');

-- Banning someone queues every file they uploaded for deletion.
create or replace function public.queue_banned_media()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.media_purge (bucket, path)
  select bucket_id, name from storage.objects
  where (storage.foldername(name))[1] = new.user_id::text
  on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists site_bans_queue_media on public.site_bans;
create trigger site_bans_queue_media after insert on public.site_bans
  for each row execute function public.queue_banned_media();

-- For the server's one-off scan of everything uploaded before this existed.
create or replace function public.unscanned_media(n int)
returns table (bucket text, path text, user_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select o.bucket_id, o.name,
    case when (storage.foldername(o.name))[1] ~ '^[0-9a-f-]{36}$' then (storage.foldername(o.name))[1]::uuid end
  from storage.objects o
  left join public.media_scans s on s.bucket = o.bucket_id and s.path = o.name
  where s.path is null
    and o.bucket_id in ('attachments', 'avatars', 'banners', 'icons', 'emojis')
    and o.name not like '%/'
    and not exists (select 1 from public.media_purge q where q.bucket = o.bucket_id and q.path = o.name)
  order by o.created_at desc
  limit n;
$$;

create or replace function public.unscanned_media_count()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*)
  from storage.objects o
  left join public.media_scans s on s.bucket = o.bucket_id and s.path = o.name
  where s.path is null
    and o.bucket_id in ('attachments', 'avatars', 'banners', 'icons', 'emojis')
    and o.name not like '%/'
    and not exists (select 1 from public.media_purge q where q.bucket = o.bucket_id and q.path = o.name);
$$;

revoke all on function public.unscanned_media(int), public.unscanned_media_count() from public, anon, authenticated;
-- media_ok must stay callable by everyone: the message trigger plans a call to it as the
-- sending user, and revoking it refused every message for 35 minutes on launch day.
grant execute on function public.media_ok(text, text) to anon, authenticated;
