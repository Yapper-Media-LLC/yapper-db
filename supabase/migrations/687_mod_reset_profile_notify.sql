-- 687: a staff profile reset tells the realtime server (bugs 4d04a255, eced2383).
-- After a mod reset, people kept seeing the old name / picture / bio for up to 5 minutes (the realtime server's
-- shared profile cache) and until they reopened the profile. mod_reset_profile now ends with rt_profile_changed
-- (migration 201: public.bc -> /publish, event 'profile'), which forgets the cached row and, with the realtime server's
-- profileHints.mjs, tells the tabs that show this person to look again. Same body as live otherwise.
-- DDL (function only, no table change): apply in quiet hours. Re-runnable.
create or replace function public.mod_reset_profile(uid uuid, parts text[], why text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  k_old text;
begin
  if length(trim(coalesce(why, ''))) < 3 then raise exception 'Give a reason'; end if;
  if parts is null or cardinality(parts) = 0 then raise exception 'Pick what to reset'; end if;
  perform public.mod_guard('reset', uid, why);
  if 'username' = any(parts) then
    -- Row first, then the name lock: the same order as a user's own rename (row lock, then the holds trigger's
    -- advisory lock), so the two can't deadlock, and FOR UPDATE waits out a rename in progress so we hold the
    -- name actually being reset, not one they just left.
    select lower(username) into k_old from public.profiles where id = uid for update;
    if k_old is not null then
      -- Same lock the holds trigger takes, so a rename grabbing this name at the same moment waits for us.
      perform pg_advisory_xact_lock(hashtext('username:' || k_old));
      -- mod_guard above guarantees a signed-in staff member, so auth.uid() is set.
      insert into public.username_holds (name_key, user_id, until)
        values (k_old, auth.uid(), now() + interval '30 days')
        on conflict (name_key) do update set user_id = excluded.user_id, until = excluded.until;
    end if;
  end if;
  update public.profiles set
    avatar_path  = case when 'avatar' = any(parts) then null else avatar_path end,
    banner_path  = case when 'banner' = any(parts) then null else banner_path end,
    bio          = case when 'bio' = any(parts) then '' else bio end,
    display_name = case when 'display_name' = any(parts) then null else display_name end,
    pronouns     = case when 'pronouns' = any(parts) then null else pronouns end,
    links        = case when 'links' = any(parts) then '[]'::jsonb else links end,
    username     = case when 'username' = any(parts) then 'user' || substr(md5(random()::text || uid::text), 1, 8) else username end
  where id = uid;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), 'profile_reset', uid, array_to_string(parts, ', ') || ': ' || left(trim(why), 250));
  -- Realtime: forget the cached row and tell the tabs showing this person (pg_net queues it, sent after commit).
  perform public.rt_profile_changed(array[uid]);
end;
$function$;
