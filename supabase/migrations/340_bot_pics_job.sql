-- 340: shrink bot pictures uploaded before bot uploads were cut down (lib/server/bots.ts shrinkBotImage), made by a
-- job like 326: every minute pg_cron posts to /api/cron/bot-pics with CRON_SECRET (vault secret request_limits_secret,
-- same value). The route keeps its place on R2 and answers at once when done. GIF avatars are left alone (they have
-- still copies, 323). No function, only a cron row: no schema change. Remove when done with
-- select cron.unschedule('bot-pics-tick'). Re-runnable.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and not exists (select 1 from cron.job where jobname = 'bot-pics-tick') then
    perform cron.schedule('bot-pics-tick', '* * * * *', $job$
      select net.http_post(
        url := 'https://www.yapper.website/api/cron/bot-pics',
        body := '{}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
          'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'request_limits_secret' limit 1)),
        timeout_milliseconds := 60000)
      where exists (select 1 from vault.decrypted_secrets where name = 'request_limits_secret')
    $job$);
  end if;
end $$;
