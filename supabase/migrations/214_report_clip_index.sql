-- 214: index for voice report clip lookups (213: report_clips_due / report_clips_cleared match on voice_clip_path).
-- reports is big, so build it without locking. Must run on its own (not inside a transaction). Re-runnable.
create index concurrently if not exists reports_voice_clip_idx on public.reports (voice_clip_path) where voice_clip_path is not null;
