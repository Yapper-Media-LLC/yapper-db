-- 233: Evidence on ban appeals (Mod Center → Ban appeals). Staff couldn't judge an appeal: it only showed the
-- ban reason. staff_ban_evidence(uid) returns what led to the ban in one go: who banned (or that it was automatic),
-- the reports against them around the ban (with the reported message), the uploads the image check blocked (the
-- picture itself comes from the private quarantine copy via /api/media/appeals?scan=...), their last messages in
-- servers (not DMs), and their earlier warnings / bans. Staff only. Re-runnable.

create or replace function public.staff_ban_evidence(uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare b public.site_bans; at timestamptz;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into b from public.site_bans where user_id = uid order by created_at desc limit 1;
  at := coalesce(b.created_at, now());
  return jsonb_build_object(
    'banned_by', (select p.username from public.profiles p where p.id = b.banned_by),
    'automatic', b.user_id is not null and b.banned_by is null,
    'ban_at', b.created_at,
    'reason', b.reason,
    'reports', coalesce((
      select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('reason', r.reason, 'details', left(coalesce(r.details, ''), 300),
          'message', left(coalesce(r.message_content, ''), 500), 'attachment', r.message_attachment is not null,
          'status', r.status, 'at', r.created_at) x
        from public.reports r
        where r.target_id = uid and r.created_at between at - interval '14 days' and at + interval '1 hour'
        order by r.created_at desc limit 10) q), '[]'::jsonb),
    'reports_total', (select count(*) from public.reports r where r.target_id = uid),
    'reporters', (select count(distinct r.reporter_id) from public.reports r where r.target_id = uid),
    'blocked_uploads', coalesce((
      select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('bucket', m.bucket, 'path', m.path, 'score', round(m.score::numeric, 2), 'at', m.scanned_at,
          'forgiven', coalesce(m.forgiven, false),
          'kept', exists (select 1 from public.upload_quarantine q where q.bucket = m.bucket and q.path = m.path and q.removed_at is null)) x
        from public.media_scans m
        where m.user_id = uid and m.verdict = 'blocked'
        order by m.scanned_at desc limit 6) q), '[]'::jsonb),
    'messages', coalesce((
      select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('content', left(m.content, 400), 'attachment', m.attachment_path is not null,
          'channel', c.name, 'server', s.name, 'at', m.created_at) x
        from public.messages m
        join public.channels c on c.id = m.channel_id and c.server_id is not null
        join public.servers s on s.id = c.server_id
        where m.author_id = uid and m.created_at <= at + interval '1 minute'
        order by m.created_at desc limit 15) q), '[]'::jsonb),
    'warnings', (select count(*) from public.user_warnings w where w.user_id = uid),
    'past_bans', (select count(*) from public.mod_log l where l.target_id = uid and l.action in ('ban', 'site_ban') and l.created_at < at - interval '1 minute')
  );
end $$;
revoke all on function public.staff_ban_evidence(uuid) from public, anon;
grant execute on function public.staff_ban_evidence(uuid) to authenticated;
