-- 277: a username a moderator resets is held for 30 days, so nobody can claim it straight away.
--
-- mod_reset_profile() renamed the person to userXXXXXXXX and the old name was free at once. Offensive names got picked
-- up again within minutes, and people whose name was reset saw someone else "snipe" it (support email, Oct 18).
-- Now the old name goes into username_holds (246) for 30 days, held by the moderator who reset it. Holds stop
-- everyone except the holder, so neither the person whose name it was nor anyone else can take it. The moderator
-- could, which doesn't matter. Holds are enforced for everyone while flag username_limits is 'everyone' (live since
-- Oct 18); username_taken() and sign-ups already respect them.
--
-- Live definition of mod_reset_profile (pg_get_functiondef, Oct 19) plus the hold. Signature, security definer,
-- search_path and grants unchanged. Re-runnable.

set lock_timeout = '2s';

create or replace function public.mod_reset_profile(uid uuid, parts text[], why text)
returns void language plpgsql security definer set search_path = public as $$
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
end;
$$;

reset lock_timeout;
