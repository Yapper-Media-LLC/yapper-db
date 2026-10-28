-- 234: indexes for staff_ban_evidence (233) and profile deletes: reports and mod_log by target. Run each on its own
-- (concurrently can't be inside a transaction). Re-runnable. Applied Oct 18.
create index concurrently if not exists reports_target_idx on public.reports (target_id, created_at desc);
create index concurrently if not exists mod_log_target_idx on public.mod_log (target_id, created_at);
