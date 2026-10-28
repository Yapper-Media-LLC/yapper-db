-- 525: fixed retention for safety data, so the Privacy Policy can promise it.
-- Device/network hashes (user_devices) were only removed by a random 0.05% cleanup in note_device (304), and sign-up IPs
-- (signup_log) were never removed. Now a nightly job deletes hashes not seen for 120 days and sign-up IPs older than
-- 90 days. Only rows change (pg_cron job row + deletes): no DDL, so no PostgREST schema reload. Re-runnable.

select cron.schedule(
  'safety-data-retention',
  '40 4 * * *',
  $job$
    delete from public.user_devices where last_seen < now() - interval '120 days';
    delete from public.signup_log where created_at < now() - interval '90 days';
  $job$
);
