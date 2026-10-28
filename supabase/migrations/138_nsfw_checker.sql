-- ============================================================
-- Yapper · Stricter NSFW checks (flag nsfw_v2)
-- * media_scans gets a picture fingerprint (phash, 64-bit difference hash) and the v2 class scores
--   (details), so the new checker can be tuned on real uploads.
-- * nsfw_hashes: fingerprints of pictures moderators took down for sexual content / minor safety.
--   With nsfw_v2 the scanner refuses close matches (re-uploads, resized or recompressed copies).
--   Filled by a trigger when a site admin or moderator marks such a report "actioned".
-- * Server banners and bot avatars are now guarded by require_scanned_media like every other image
--   column (before, only the set_server_banner RPC and the bot API checked them).
-- Re-runnable.
-- ============================================================

alter table public.media_scans add column if not exists phash bigint;
alter table public.media_scans add column if not exists details jsonb;

create table if not exists public.nsfw_hashes (
  phash bigint primary key,
  source text not null default 'report',
  bucket text,
  path text,
  report_id uuid,
  added_by uuid,
  added_at timestamptz not null default now()
);
-- Server only (service role): no policies, nobody else can read or write it.
alter table public.nsfw_hashes enable row level security;
revoke all on public.nsfw_hashes from anon, authenticated;

-- Is this fingerprint within `maxdist` bits of a taken-down picture? Blank-ish fingerprints
-- (almost all 0s or 1s) say nothing about the picture and never match.
create or replace function public.nsfw_hash_hit(h text, maxdist int default 5)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select bit_count(h::bigint::bit(64)) between 6 and 58
     and exists (
       select 1 from public.nsfw_hashes x
       where bit_count((x.phash # h::bigint)::bit(64)) <= least(greatest(maxdist, 0), 10)
     );
$$;
revoke all on function public.nsfw_hash_hit(text, int) from public, anon, authenticated;
grant execute on function public.nsfw_hash_hit(text, int) to service_role;

-- A sexual / minor-safety report on a picture, actioned by a site admin or site moderator:
-- remember the picture's fingerprint so the same picture can't just be sent again.
create or replace function public.nsfw_hash_from_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'actioned' and old.status is distinct from 'actioned'
     and new.reason in ('sexual', 'minor_safety')
     and new.message_attachment is not null
     and new.resolved_by is not null
     and (exists (select 1 from public.site_admins a where a.user_id = new.resolved_by)
          or exists (select 1 from public.site_moderators m where m.user_id = new.resolved_by)) then
    insert into public.nsfw_hashes (phash, source, bucket, path, report_id, added_by)
    select s.phash, 'report', s.bucket, s.path, new.id, new.resolved_by
    from public.media_scans s
    where s.bucket = 'attachments' and s.path = new.message_attachment
      and s.phash is not null and bit_count(s.phash::bit(64)) between 6 and 58
    on conflict (phash) do nothing;
  end if;
  return null;
end;
$$;
revoke all on function public.nsfw_hash_from_report() from public, anon, authenticated;
create or replace trigger reports_nsfw_hash
  after update of status on public.reports
  for each row execute function public.nsfw_hash_from_report();

-- Server banners and bot avatars: same rule as every other picture column.
create or replace trigger servers_scanned_media
  before insert or update of icon_path, banner_path on public.servers
  for each row execute function public.require_scanned_media('icon_path', 'icons', 'banner_path', 'banners');
create or replace trigger bots_scanned_media
  before insert or update of avatar_path on public.bots
  for each row execute function public.require_scanned_media('avatar_path', 'avatars');

-- The flag: test servers / Antic only until it's published.
insert into public.feature_flags (key, label, description, mode, servers, users)
values (
  'nsfw_v2',
  'Stricter NSFW checks',
  'Second model, counts "sexy", looks at tiles of big pictures and more frames of GIFs/videos, plays animated PNGs, checks see-through pictures on dark too, lower bar for avatars/banners/icons/emojis, and blocks re-uploads of pictures mods took down.',
  'test',
  array['00000000-0000-4000-8000-00000000b001']::uuid[],
  array['00000000-0000-4000-8000-00000000a001']::uuid[]
)
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- Security review fixes
-- ------------------------------------------------------------

-- Only a report that site staff confirmed one by one (resolve_report) feeds nsfw_hashes. Bans close
-- all of a person's open reports in bulk; hashing those let an alt's bogus "sexual" report on a normal
-- meme plus an unrelated ban block that meme for everyone.
create or replace function public.resolve_report(rid uuid, new_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid;
begin
  select server_id into sid from public.reports where id = rid;
  if not (public.is_staff() or (sid is not null and public.server_perm(sid, 'manage_server'))) then raise exception 'Not allowed'; end if;
  if new_status not in ('open', 'actioned', 'dismissed') then raise exception 'Bad status'; end if;
  -- Site staff confirming this one report: its picture may go on the take-down list (nsfw_hash_from_report).
  if new_status = 'actioned' and public.is_staff() then
    perform set_config('yapper.nsfw_confirm', '1', true);
  end if;
  update public.reports
     set status = new_status,
         resolved_by = case when new_status = 'open' then null else auth.uid() end,
         resolved_at = case when new_status = 'open' then null else now() end
   where id = rid;
  perform set_config('yapper.nsfw_confirm', '', true);
end;
$$;

create or replace function public.nsfw_hash_from_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('yapper.nsfw_confirm', true), '') = '1'
     and new.status = 'actioned' and old.status is distinct from 'actioned'
     and new.reason in ('sexual', 'minor_safety')
     and new.message_attachment is not null
     and new.resolved_by is not null
     and new.resolved_by = auth.uid()
     and public.is_staff_user(new.resolved_by) then
    insert into public.nsfw_hashes (phash, source, bucket, path, report_id, added_by)
    select s.phash, 'report', s.bucket, s.path, new.id, new.resolved_by
    from public.media_scans s
    where s.bucket = 'attachments' and s.path = new.message_attachment
      and s.phash is not null and bit_count(s.phash::bit(64)) between 6 and 58
    on conflict (phash) do nothing;
  end if;
  return null;
end;
$$;
revoke all on function public.nsfw_hash_from_report() from public, anon, authenticated;

-- For the scan route's per-person rate limit (checks in the last minute).
create index if not exists media_scans_user_time_idx on public.media_scans (user_id, scanned_at);
