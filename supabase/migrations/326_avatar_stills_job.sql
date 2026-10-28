-- 326: still copies for GIF avatars uploaded before they existed (flag gif_avatar_still, 323/324), made by a job
-- instead of the Admin button: every minute pg_cron posts to /api/cron/avatar-stills with CRON_SECRET (vault secret
-- request_limits_secret, same value). The route keeps its place on R2 and answers at once when done.
-- No function, only a cron row: no schema change. Remove when done with select cron.unschedule('avatar-stills-tick').
-- Re-runnable.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and not exists (select 1 from cron.job where jobname = 'avatar-stills-tick') then
    perform cron.schedule('avatar-stills-tick', '* * * * *', $job$
      select net.http_post(
        url := 'https://www.yapper.website/api/cron/avatar-stills',
        body := '{}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
          'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'request_limits_secret' limit 1)),
        timeout_milliseconds := 60000)
      where exists (select 1 from vault.decrypted_secrets where name = 'request_limits_secret')
    $job$);
  end if;
end $$;
