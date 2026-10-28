-- 213: Voice report clips (flag voice_report_clips, test mode).
-- While someone is in a voice channel their own client keeps the last 30 seconds of call audio in memory.
-- Only when they report someone in that call is the clip uploaded, to a PRIVATE storage bucket, and linked
-- to the report. Only Yapper staff can play it (10 minute signed link, made in the staff report view). Clips are deleted
-- 30 days after the report is resolved (pg_cron -> /api/cron/report-clips), and unlinked uploads after a day.
-- Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers)
values ('voice_report_clips', 'Voice report clips', 'Reports from voice channels can attach the last 30 seconds of call audio (staff only)', 'test', '{}')
on conflict (key) do nothing;

alter table public.reports add column if not exists voice_clip_path text;

-- Private bucket: WAV, 16 kHz mono, 30 s is about 1 MB. 2 MB cap.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('report_clips', 'report_clips', false, 2097152, array['audio/wav'])
on conflict (id) do update set public = false, file_size_limit = 2097152, allowed_mime_types = array['audio/wav'];

-- An upload is only allowed into the one open slot of your own fresh voice report: <me>/<report id>.wav,
-- with the flag on and no clip attached yet. So the bucket can't be used as free file hosting.
create or replace function public.can_upload_report_clip(n text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select n ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.wav$'
    and split_part(n, '/', 1) = (select auth.uid())::text
    and exists (
      select 1 from public.reports r
      where r.id = substring(n from '^[0-9a-f-]{36}/([0-9a-f-]{36})\.wav$')::uuid
        and r.reporter_id = (select auth.uid())
        and r.details like '[voice]%'
        and r.voice_clip_path is null
        and r.created_at > now() - interval '10 minutes'
        and public.feature_on('voice_report_clips', r.server_id));
$$;
revoke all on function public.can_upload_report_clip(text) from public, anon;
grant execute on function public.can_upload_report_clip(text) to authenticated;

-- Read: staff only (the reporter never needs to play it back). No update or delete for anyone but the service role.
drop policy if exists "report_clips: upload own" on storage.objects;
create policy "report_clips: upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'report_clips' and public.can_upload_report_clip(name));
drop policy if exists "report_clips: staff read" on storage.objects;
create policy "report_clips: staff read" on storage.objects for select to authenticated
  using (bucket_id = 'report_clips' and (select public.is_staff()));

-- Links an uploaded clip to the caller's own fresh voice report. The path is fixed (<me>/<report id>.wav),
-- so a clip can't be pointed at someone else's file or attached to an old report.
create or replace function public.attach_report_clip(rid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r public.reports; p text;
begin
  select * into r from public.reports where id = rid;
  if r.id is null or r.reporter_id is distinct from auth.uid() then raise exception 'Report not found'; end if;
  if r.details is null or r.details not like '[voice]%' then raise exception 'Only voice reports can have a clip'; end if;
  if not public.feature_on('voice_report_clips', r.server_id) then raise exception 'Voice clips aren''t available here yet'; end if;
  if r.created_at < now() - interval '10 minutes' then raise exception 'Too late to attach a clip'; end if;
  if r.voice_clip_path is not null then raise exception 'This report already has a clip'; end if;
  p := auth.uid()::text || '/' || rid::text || '.wav';
  if not exists (select 1 from storage.objects where bucket_id = 'report_clips' and name = p) then
    raise exception 'Clip upload not found';
  end if;
  update public.reports set voice_clip_path = p where id = rid;
end $$;
revoke all on function public.attach_report_clip(uuid) from public, anon;
grant execute on function public.attach_report_clip(uuid) to authenticated;

-- For the cleanup route (service role only): clips whose report was resolved over 30 days ago,
-- plus uploads that never got linked to a report within a day.
create or replace function public.report_clips_due(lim int default 200)
returns table (path text)
language sql
stable
security definer
set search_path = public
as $$
  (select r.voice_clip_path from public.reports r
    where r.voice_clip_path is not null and r.resolved_at is not null and r.resolved_at < now() - interval '30 days'
    limit lim)
  union all
  (select o.name from storage.objects o
    where o.bucket_id = 'report_clips' and o.created_at < now() - interval '1 day'
      and not exists (select 1 from public.reports r where r.voice_clip_path = o.name)
    limit lim);
$$;
revoke all on function public.report_clips_due(int) from public, anon, authenticated;

create or replace function public.report_clips_cleared(paths text[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.reports set voice_clip_path = null where voice_clip_path = any(paths);
$$;
revoke all on function public.report_clips_cleared(text[]) from public, anon, authenticated;

-- Daily kick, same secret and pattern as request_limits_kick (191). Does nothing while there are no clips
-- or the vault secret is missing.
create or replace function public.report_clips_kick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare secret text;
begin
  -- Runs while there are clips at all (also with the flag turned off later, so old clips still get deleted).
  if not exists (select 1 from storage.objects where bucket_id = 'report_clips') then return; end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'request_limits_secret' limit 1;
  if coalesce(secret, '') = '' then return; end if;
  perform net.http_post(
    url := 'https://www.yapper.website/api/cron/report-clips',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret),
    timeout_milliseconds := 30000);
end $$;
revoke all on function public.report_clips_kick() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    if not exists (select 1 from cron.job where jobname = 'report-clips-cleanup') then
      perform cron.schedule('report-clips-cleanup', '17 3 * * *', 'select public.report_clips_kick()');
    end if;
  end if;
end $$;
