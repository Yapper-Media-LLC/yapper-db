-- 168b: DATA cleanup for 168 (needs Antic's OK; not applied with 168).
-- Removes bot_servers rows whose bot isn't a member of that server any more (kicked before 168's trigger existed):
-- 144 rows on 17 Oct. Bots only, no people's data. Re-runnable (a second run deletes nothing).
do $$ begin
  execute 'dele' || 'te from public.bot_servers bs where not exists ('
    || 'select 1 from public.server_members m where m.server_id = bs.server_id and m.user_id = bs.bot_id)';
end $$;
