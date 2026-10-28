-- Second opinion on flagged pictures, part 2 (after review of 221):
-- 1. image_reviews: Claude's verdict per exact picture (sha256), so the same bytes are never paid for twice, and a
--    per-person daily allowance (lib/server/media.ts secondOpinion). Server-only: no policies, no grants.
-- 2. staff_decide_appeal: approving an appeal lifts an automatic ban by the same rules media.ts now bans by
--    (distinct pictures by fingerprint; one picture is only "flagrant" when the second opinion was sure), and the
--    allowlist keeps the local checker's own score.

create table if not exists public.image_reviews (
  sha256 text primary key,
  user_id uuid references auth.users(id) on delete set null,
  rating text not null check (rating in ('explicit', 'suggestive', 'safe')),
  minor boolean not null default false,
  confidence real not null default 0,
  reason text not null default '',
  model text not null default '',
  at timestamptz not null default now()
);
create index if not exists image_reviews_user_at on public.image_reviews (user_id, at);
alter table public.image_reviews enable row level security;
revoke all on public.image_reviews from anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_decide_appeal(aid uuid, approve boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    known := coalesce((a.details ->> 'hashHit')::boolean, false) or (a.phash is not null and public.nsfw_hash_hit(a.phash::text));
    if public.is_site_admin() and not known and a.sha256 is not null then
      -- The local checker's own score when a second opinion lowered the stored one, so the next upload of
      -- these bytes (scored locally again) is still covered by the allowlist.
      insert into public.nsfw_allowed_hashes as x (sha256, bucket, score, appeal_id, added_by)
      values (a.sha256, a.bucket, greatest(coalesce(a.score, 0), coalesce((a.details -> 'review' ->> 'local')::real, 0)), aid, me)
      on conflict (sha256) do update
        set bucket = case when excluded.bucket <> 'attachments' then excluded.bucket else x.bucket end,
            score = greatest(x.score, excluded.score), appeal_id = excluded.appeal_id, added_by = excluded.added_by, added_at = now();
      can_allow := true;
    end if;
    select * into ban from public.site_bans
     where user_id = a.user_id and banned_by is null and expires_at is not null and expires_at > now()
       and reason in ('Uploading sexual images or videos', 'Uploading sexual images')
     for update;
    if found and sc_at is not null and sc_at between ban.created_at - interval '1 day' and ban.created_at + interval '5 minutes' then
      -- Same rules as lib/server/media.ts (Oct 18): strikes are distinct pictures (by fingerprint; animations by
      -- fingerprint and score), and a single picture only justifies a ban when the second opinion was sure.
      select count(distinct case
               when phash is null then 's' || round(score * 1000)::text
               when coalesce((details ->> 'frames')::int, 1) > 1 then phash::text || ':' || round(score * 1000)::text
               else phash::text end) filter (where score < 1),
             coalesce(bool_or(
               (details -> 'review' ->> 'rating' = 'explicit' and coalesce((details -> 'review' ->> 'confidence')::real, 0) >= 0.9)
               or (coalesce((details -> 'review' ->> 'minor')::boolean, false) and coalesce((details -> 'review' ->> 'confidence')::real, 0) >= 0.8)
             ), false)
        into n_distinct, flagrant
        from public.media_scans
       where user_id = a.user_id and verdict = 'blocked' and not forgiven and score >= 0.9
         and scanned_at between ban.created_at - interval '1 day' and ban.created_at + interval '5 minutes';
      if n_distinct < 3 and not flagrant then
        if not public.is_site_admin() then perform public.mod_guard('unban', a.user_id, null); end if;
        update public.site_bans set expires_at = now()
         where user_id = ban.user_id and banned_by is null and reason = ban.reason
           and created_at = ban.created_at and expires_at = ban.expires_at;
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
$function$;
