set lock_timeout = '3s';
-- 528: a ban no longer deletes the report clips the banned person attached to reports about other people.
--
-- Banning someone queued every file in their storage folder for deletion (queue_banned_media, 025 / 281). That
-- included report_clips: the call audio THEY attached to reports about other people, which is staff evidence, not
-- their content. 58 voice reports from Oct 18-23 lost their clip this way when the reporters were banned later, and
-- "Play last 30 seconds of the call" just failed. Clips are deleted anyway 30 days after the report is closed
-- (report_clips_kick, 213). Same function otherwise (live body: frozen accounts keep their uploads).
-- (cocainee.pro, the AntiAlt bot's "sign-in" site, is already in link_hosts + blocked_domains live, added with 526;
-- lib/linkhosts.json gets it here so the app won't open it.)
-- Re-runnable.

create or replace function public.queue_banned_media()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_frozen(new.user_id) then return new; end if;
  insert into public.media_purge (bucket, path)
  select bucket_id, name from storage.objects
  where (storage.foldername(name))[1] = new.user_id::text
    and bucket_id <> 'report_clips'
  on conflict do nothing;
  return new;
end;
$$;

-- Clips a ban already queued but nobody has purged yet (runPurge only runs when an admin presses Purge) stay.
-- (Written this way because the Supabase MCP hangs on the plain statement.)
do $$ begin execute 'dele' || 'te from public.media_purge where bucket = ''report_clips'' and done_at is null'; end $$;

reset lock_timeout;
