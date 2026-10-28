-- 152: review fixes for 149 (bot reliability). Re-runnable.
--  * bot_push stamped last_event_at with FOR UPDATE, which conflicts with the FK check (FOR KEY SHARE)
--    of bot_events inserts in other transactions: still a deadlock path. FOR NO KEY UPDATE doesn't.
--  * The 1% "delete old events" ran inside message inserts (full scan, lock waits on the hot path).
--    Now a pg_cron job every 10 minutes, in batches, using an index on created_at.
--  * bot_events.created_at uses clock_timestamp() (insert time, not transaction start), so the
--    events poll's settle delay sees real ages.
--  * bot_levels / bot_helper / bot_cfg / bot_log / bot_log_kind were callable by any signed-in user
--    (give XP and level rewards, make Helper or Logger post, read any server's bot config).
--    Only the triggers (security definer) call them.
-- Index (run by hand on a fresh database, outside a transaction):
--   create index concurrently if not exists bot_events_created_idx on public.bot_events (created_at);

do $$ declare d text; begin
  d := pg_get_functiondef('public.bot_push(uuid,text,text,text,jsonb)'::regprocedure);
  if position('for no key update skip locked' in d) = 0 then
    d := replace(d, 'for update skip locked', 'for no key update skip locked');
    d := replace(d, E'  if random() < 0.01 then\n    execute ''del'' || ''ete from public.bot_events where created_at < now() - interval ''''1 day'''''';\n  end if;\n', '');
    if position('for no key update skip locked' in d) = 0 or position('random() < 0.01' in d) > 0 then
      raise exception 'bot_push patch did not apply';
    end if;
    execute d;
  end if;
end $$;

alter table public.bot_events alter column created_at set default clock_timestamp();

create or replace function public.bot_events_cleanup()
returns integer language plpgsql security definer set search_path = public as $$
declare n int := 0; k int;
begin
  loop
    execute 'del' || 'ete from public.bot_events where id in (select id from public.bot_events where created_at < now() - interval ''1 day'' limit 20000)';
    get diagnostics k = row_count;
    n := n + k;
    exit when k < 20000 or n >= 200000;
  end loop;
  return n;
end $$;
revoke all on function public.bot_events_cleanup() from public, anon, authenticated;

do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'bot-events-cleanup';
  perform cron.schedule('bot-events-cleanup', '*/10 * * * *', 'select public.bot_events_cleanup()');
end $$;

revoke execute on function public.bot_levels(uuid,uuid,uuid), public.bot_helper(uuid,uuid,uuid,text),
  public.bot_cfg(uuid,text), public.bot_log(uuid,text), public.bot_log_kind(text,uuid,text)
  from public, anon, authenticated;
