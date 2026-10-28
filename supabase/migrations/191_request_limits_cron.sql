-- 191: runs the request-limit detector (app/api/cron/request-limits) every 3 minutes from pg_cron through pg_net,
-- the same way other jobs here call out (no Vercel cron needed, whatever the Vercel plan allows).
--
-- Needs two vault secrets, added by hand (never in a migration):
--   request_limits_secret  the same random string as CRON_SECRET in Vercel (the route refuses anything else)
--   request_limits_url     optional, defaults to https://www.yapper.website/api/cron/request-limits
-- Without the secret, or with the request_limits flag off, the job does nothing (no request goes out).
-- Re-runnable.

create or replace function public.request_limits_kick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  secret text;
  url text;
begin
  if not exists (select 1 from public.feature_flags where key = 'request_limits' and mode <> 'off') then return; end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'request_limits_secret' limit 1;
  if coalesce(secret, '') = '' then return; end if;
  select decrypted_secret into url from vault.decrypted_secrets where name = 'request_limits_url' limit 1;
  perform net.http_post(
    url := coalesce(nullif(url, ''), 'https://www.yapper.website/api/cron/request-limits'),
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret),
    timeout_milliseconds := 30000);
end $$;
revoke all on function public.request_limits_kick() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    if not exists (select 1 from cron.job where jobname = 'request-limits-tick') then
      perform cron.schedule('request-limits-tick', '*/3 * * * *', 'select public.request_limits_kick()');
    end if;
  end if;
end $$;
