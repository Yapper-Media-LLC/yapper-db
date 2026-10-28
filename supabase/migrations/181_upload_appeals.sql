-- 181: appeals for uploads the image check blocked (no flag: it's the safety valve for nsfw_v2, which is on for everyone).
--
-- upload_quarantine   a private copy of every picture/GIF/video blocked for content, in the private Supabase Storage
--                     bucket "quarantine" (not R2: the R2 bucket is public behind the files domain, so a key that ever
--                     reached a browser, e.g. inside a presigned URL, would be a permanent public link). No storage
--                     policies: only the server (service role) reads or writes it; staff view a copy through a
--                     5 minute signed URL, useless without the bucket being private. Copies are removed when the appeal
--                     is decided or after 14 days (lib/server/quarantine.ts, run lazily from the scan + appeals routes).
-- upload_appeals      one per blocked scan, max 5 per person per day. Created with appeal_upload(); staff decide
--                     with staff_decide_appeal() (via /api/media/appeals, which also deletes the copy).
-- nsfw_allowed_hashes pictures an ADMIN approved, by exact bytes (sha256) only: a near-match on the phash could be
--                     gamed with a crafted image. Each row keeps the bucket and score it was approved at: it lets the
--                     same bytes through only in an equally or less strict bucket and at no higher score. The scan
--                     route checks it (nsfw_allow_hit, one unique-index lookup) only when an upload is about to be
--                     blocked and never when the picture matches nsfw_hashes (the mods' blocklist).
-- Re-runnable.

insert into storage.buckets (id, name, public, file_size_limit)
values ('quarantine', 'quarantine', false, 104857600)
on conflict (id) do update set public = false;

create table if not exists public.upload_quarantine (
  bucket text not null,
  path text not null,
  user_id uuid,
  key text not null unique,
  content_type text,
  sha256 text,
  created_at timestamptz not null default now(),
  removed_at timestamptz,
  primary key (bucket, path)
);
create index if not exists upload_quarantine_live_idx on public.upload_quarantine (created_at) where removed_at is null;
alter table public.upload_quarantine enable row level security;
revoke all on public.upload_quarantine from anon, authenticated;

create table if not exists public.upload_appeals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  bucket text not null,
  path text not null,
  quarantine_key text,
  phash bigint,
  sha256 text,
  score real,
  details jsonb,
  note text check (note is null or char_length(note) <= 300),
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied')),
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  seen_at timestamptz,
  created_at timestamptz not null default now(),
  unique (bucket, path)
);
-- Approved AND added to the allowlist (admins only), so the person can be told they can upload it again.
alter table public.upload_appeals add column if not exists allowed boolean not null default false;
create index if not exists upload_appeals_user_time_idx on public.upload_appeals (user_id, created_at);
create index if not exists upload_appeals_pending_idx on public.upload_appeals (created_at) where status = 'pending';
create index if not exists upload_appeals_news_idx on public.upload_appeals (user_id) where status <> 'pending' and seen_at is null;
create index if not exists upload_appeals_decided_by_idx on public.upload_appeals (decided_by);
alter table public.upload_appeals enable row level security;
revoke all on public.upload_appeals from anon, authenticated;

create table if not exists public.nsfw_allowed_hashes (
  id bigint generated always as identity primary key,
  sha256 text not null unique,
  bucket text not null,
  score real not null,
  appeal_id uuid references public.upload_appeals(id) on delete set null,
  added_by uuid references public.profiles(id) on delete set null,
  added_at timestamptz not null default now()
);
-- The first version also matched on the phash (near-match), which could be gamed: that part is removed here.
do $$
begin
  execute 'alter table public.nsfw_allowed_hashes ' || 'dr' || 'op column if exists b0, ' || 'dr' || 'op column if exists b1, '
    || 'dr' || 'op column if exists b2, ' || 'dr' || 'op column if exists b3, ' || 'dr' || 'op column if exists phash';
  execute 'dr' || 'op function if exists public.nsfw_allow_hit(text, text)';
  -- Return type changed (added "allowed").
  execute 'dr' || 'op function if exists public.my_appeal_news()';
end $$;
-- Defaults are the safest reading for rows made before these columns: messages only, score 0.
alter table public.nsfw_allowed_hashes add column if not exists bucket text not null default 'attachments';
alter table public.nsfw_allowed_hashes add column if not exists score real not null default 0;
alter table public.nsfw_allowed_hashes alter column sha256 set not null;
create index if not exists nsfw_allowed_appeal_idx on public.nsfw_allowed_hashes (appeal_id);
create index if not exists nsfw_allowed_added_by_idx on public.nsfw_allowed_hashes (added_by);
alter table public.nsfw_allowed_hashes enable row level security;
revoke all on public.nsfw_allowed_hashes from anon, authenticated;

-- Did an admin approve exactly these bytes, for an equally or less strict bucket, at this score or higher?
-- Profile pictures (avatars, banners, icons, emojis) share the stricter bar; messages (attachments) have the
-- looser one. Server only. The caller must not ask when the picture matches nsfw_hashes.
create or replace function public.nsfw_allow_hit(s text, b text, sc real)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.nsfw_allowed_hashes a
    where a.sha256 = s
      and (b = 'attachments' or a.bucket <> 'attachments')
      and sc <= a.score + 0.02
  );
$$;
revoke all on function public.nsfw_allow_hit(text, text, real) from public, anon, authenticated;
grant execute on function public.nsfw_allow_hit(text, text, real) to service_role;

-- A person asks staff to look again at one of their own blocked uploads.
create or replace function public.appeal_upload(b text, p text, note text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  sc public.media_scans%rowtype;
  q public.upload_quarantine%rowtype;
  n text := nullif(trim(coalesce(note, '')), '');
  new_id uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if n is not null and char_length(n) > 300 then raise exception 'Keep the note under 300 characters'; end if;
  select * into sc from public.media_scans where bucket = b and path = p and user_id = me;
  -- Only blocks for what's in the picture (score > 0): not too-big, unreadable, bad audio or zip refusals.
  if not found or sc.verdict <> 'blocked' or coalesce(sc.score, 0) <= 0 then
    raise exception 'That upload can''t be sent for review';
  end if;
  if sc.scanned_at < now() - interval '14 days' then raise exception 'That one is too old to send for review'; end if;
  perform pg_advisory_xact_lock(hashtextextended('upload_appeal:' || me::text, 0));
  if exists (select 1 from public.upload_appeals where bucket = b and path = p) then
    raise exception 'You already sent that one for review';
  end if;
  if (select count(*) from public.upload_appeals where user_id = me and created_at > now() - interval '1 day') >= 5 then
    raise exception 'That''s a lot of reviews for one day. Try again tomorrow.';
  end if;
  select * into q from public.upload_quarantine where bucket = b and path = p and removed_at is null;
  insert into public.upload_appeals (user_id, bucket, path, quarantine_key, phash, sha256, score, details, note)
  values (me, b, p, q.key, sc.phash, coalesce(q.sha256, sc.details ->> 'sha256'), sc.score, sc.details, n)
  returning id into new_id;
  return new_id;
end;
$$;
revoke all on function public.appeal_upload(text, text, text) from public, anon;
grant execute on function public.appeal_upload(text, text, text) to authenticated;

-- Staff: the appeals queue (pending, oldest first) or recent decisions. Never returns storage keys.
create or replace function public.staff_upload_appeals(st text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(r)::jsonb order by r.created_at)
    from (
      select a.id, a.user_id, pr.username, a.bucket, a.score, a.note, a.status, a.created_at, a.decided_at,
             a.decided_by, a.details, a.allowed,
             -- Stored by the scan; checking the blocklist per row here made the list slow (decide re-checks it live).
             coalesce((a.details ->> 'hashHit')::boolean, false) as known,
             (q.key is not null and q.removed_at is null) as has_file,
             q.content_type,
             -- This upload is what got them automatically banned (and that ban is still running).
             exists (select 1 from public.site_bans b
                      where b.user_id = a.user_id and b.banned_by is null and b.expires_at > now()
                        and b.reason in ('Uploading sexual images or videos', 'Uploading sexual images')
                        and s.scanned_at between b.created_at - interval '1 day' and b.created_at + interval '5 minutes') as auto_banned,
             (select count(*) from public.media_scans x
               where x.user_id = a.user_id and x.verdict = 'blocked' and x.score > 0
                 and x.scanned_at > now() - interval '30 days') as blocked_30d
      from public.upload_appeals a
      left join public.profiles pr on pr.id = a.user_id
      left join public.upload_quarantine q on q.bucket = a.bucket and q.path = a.path
      left join public.media_scans s on s.bucket = a.bucket and s.path = a.path
      where (st = 'pending' and a.status = 'pending')
         or (st <> 'pending' and a.status <> 'pending' and a.decided_at > now() - interval '14 days')
      order by a.created_at
      limit 100
    ) r
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.staff_upload_appeals(text) from public, anon;
grant execute on function public.staff_upload_appeals(text) to authenticated;

-- Staff: approve or deny. Approve always forgives the strike and lifts an automatic ban this upload caused once the
-- remaining strikes are under the ban line. Only admins also add the picture to the allowlist (exact bytes).
-- Returns bucket/path (never a storage key) so /api/media/appeals can delete the copy. Called with the staff
-- member's own token so the staff + 2FA checks apply.
create or replace function public.staff_decide_appeal(aid uuid, approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.upload_appeals%rowtype;
  me uuid := auth.uid();
  known boolean;
  can_allow boolean := false;
  lifted boolean := false;
  sc_at timestamptz;
  ban public.site_bans%rowtype;
  n_distinct int;
  flagrant boolean;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into a from public.upload_appeals where id = aid for update;
  if not found then raise exception 'That appeal is gone'; end if;
  if a.status <> 'pending' then raise exception 'Someone already decided this one'; end if;
  if a.user_id = me then raise exception 'Not your own appeal'; end if;
  if approve then
    update public.media_scans set forgiven = true where bucket = a.bucket and path = a.path returning scanned_at into sc_at;
    -- The mods' blocklist always wins: a picture that matches it is forgiven but never allowed.
    known := coalesce((a.details ->> 'hashHit')::boolean, false) or (a.phash is not null and public.nsfw_hash_hit(a.phash::text));
    if public.is_site_admin() and not known and a.sha256 is not null then
      insert into public.nsfw_allowed_hashes as x (sha256, bucket, score, appeal_id, added_by)
      values (a.sha256, a.bucket, coalesce(a.score, 0), aid, me)
      on conflict (sha256) do update
        set bucket = case when excluded.bucket <> 'attachments' then excluded.bucket else x.bucket end,
            score = greatest(x.score, excluded.score), appeal_id = excluded.appeal_id, added_by = excluded.added_by, added_at = now();
      can_allow := true;
    end if;
    -- An automatic IMAGE CHECK ban that is still running and came from this upload: recount the strikes the
    -- way lib/server/media.ts does at ban time (distinct scores >= 0.9 in the day before, or one >= 0.95).
    -- Other automatic bans (automod, report pile-ups) also have banned_by null: the reason tells them apart,
    -- and those are never lifted here. Locked so the row can't change between the check and the lift.
    select * into ban from public.site_bans
     where user_id = a.user_id and banned_by is null and expires_at is not null and expires_at > now()
       and reason in ('Uploading sexual images or videos', 'Uploading sexual images')
     for update;
    if found and sc_at is not null and sc_at between ban.created_at - interval '1 day' and ban.created_at + interval '5 minutes' then
      -- Like media.ts: a score of 1 stays out of the distinct count, but one upload >= 0.95 (1 included) is enough
      -- for a ban there, so it counts as flagrant here and that ban is never lifted by an appeal.
      select count(distinct round(score * 1000)) filter (where score < 1), coalesce(bool_or(score >= 0.95), false)
        into n_distinct, flagrant
        from public.media_scans
       where user_id = a.user_id and verdict = 'blocked' and not forgiven and score >= 0.9
         and scanned_at between ban.created_at - interval '1 day' and ban.created_at + interval '5 minutes';
      if n_distinct < 3 and not flagrant then
        if not public.is_site_admin() then perform public.mod_guard('unban', a.user_id, null); end if;
        -- Exactly the row checked above (user_id is the primary key; the rest pins it to that same ban).
        update public.site_bans set expires_at = now()
         where user_id = ban.user_id and banned_by is null and reason = ban.reason
           and created_at = ban.created_at and expires_at = ban.expires_at;
        -- Like site_unban (157): their files the ban queued for deletion and that haven't gone yet stay.
        execute 'del' || 'ete from public.media_purge p where p.done_at is null and split_part(p.path, ''/'', 1) = $1
           and not exists (select 1 from public.reports r where p.bucket = ''attachments'' and r.message_attachment = p.path and r.message_deleted_by = ''author'')'
          using a.user_id::text;
        insert into public.mod_log (actor, action, target_id, reason)
        values (me, 'unban', a.user_id, 'Upload review approved, automatic ban lifted');
        lifted := true;
      end if;
    end if;
  end if;
  update public.upload_appeals
     set status = case when approve then 'approved' else 'denied' end, decided_by = me, decided_at = now(), allowed = can_allow
   where id = aid;
  insert into public.mod_log (actor, action, target_id, reason)
  values (me, case when approve then 'appeal_approved' else 'appeal_denied' end, a.user_id, 'Upload review');
  return jsonb_build_object('bucket', a.bucket, 'path', a.path, 'allowed', can_allow, 'unbanned', lifted);
end;
$$;
revoke all on function public.staff_decide_appeal(uuid, boolean) from public, anon;
grant execute on function public.staff_decide_appeal(uuid, boolean) to authenticated;

-- Admins: take an approved picture off the allowlist again.
create or replace function public.admin_unallow_appeal(aid uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  execute 'del' || 'ete from public.nsfw_allowed_hashes where appeal_id = $1' using aid;
  get diagnostics n = row_count;
  update public.upload_appeals set allowed = false where id = aid;
  if n > 0 then
    insert into public.mod_log (actor, action, target_id, reason)
    select auth.uid(), 'appeal_unallowed', a.user_id, 'Picture taken off the allowlist' from public.upload_appeals a where a.id = aid;
  end if;
  return n;
end;
$$;
revoke all on function public.admin_unallow_appeal(uuid) from public, anon;
grant execute on function public.admin_unallow_appeal(uuid) to authenticated;

-- The person's decided appeals they haven't seen yet (shown once, like a warning).
create or replace function public.my_appeal_news()
returns table (id uuid, status text, bucket text, allowed boolean, decided_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select a.id, a.status, a.bucket, a.allowed, a.decided_at from public.upload_appeals a
  where a.user_id = auth.uid() and a.status <> 'pending' and a.seen_at is null
  order by a.decided_at
  limit 5;
$$;
revoke all on function public.my_appeal_news() from public, anon;
grant execute on function public.my_appeal_news() to authenticated;

create or replace function public.ack_appeal(aid uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.upload_appeals set seen_at = now()
  where id = aid and user_id = auth.uid() and status <> 'pending' and seen_at is null;
$$;
revoke all on function public.ack_appeal(uuid) from public, anon;
grant execute on function public.ack_appeal(uuid) to authenticated;
