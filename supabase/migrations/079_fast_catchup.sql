-- channel_messages_since(cid, since, lim): catch-up bundle without per-row RLS cost; open_reports_count() for staff
-- (plus partial index reports_open_idx). Applied live Oct 14.
create index if not exists reports_open_idx on public.reports (status) where status = 'open';
