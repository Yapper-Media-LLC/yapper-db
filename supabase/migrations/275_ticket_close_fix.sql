set lock_timeout = '3s';
-- 275: mods couldn't close a ticket once another mod (or admin) had posted in it (Minecraft, Oct 19).
-- Closing deletes the channel, which deletes its messages one by one. log_mod_delete treated each one as a mod
-- deleting someone's message: mod_guard refuses "another moderator" (and the 60 an hour limit), so the whole close
-- failed and only an admin could close it.
-- Fix: deleting a whole channel isn't deleting a message. Messages removed by a cascade (channel or server delete)
-- skip the guard. They're still written to mod_log.
-- Re-runnable.

create or replace function public.log_mod_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('yapper.bulk', true), '') = '1' then return old; end if;
  if auth.uid() is not null and old.author_id <> auth.uid() and public.is_site_mod() and not public.is_site_admin() then
    -- Removed because its whole channel (or server) was deleted, e.g. a ticket closed: still logged, but not refused
    -- as "moderating another moderator" (only single messages are).
    if pg_trigger_depth() <= 1 then perform public.mod_guard('delete', old.author_id, ''); end if;
    insert into public.mod_log (actor, action, target_id, message_id, reason) values (auth.uid(), 'delete', old.author_id, old.id, left(coalesce(old.content, ''), 120));
  end if;
  return old;
end;
$$;

reset lock_timeout;
