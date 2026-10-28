-- 332: moderators may unban 60 people an hour (was 10). Antic, Oct 21, after the bot raid: mods hit the unban cap
-- fixing mistaken bans. Patches only the unban number in mod_guard (its full text lives in no migration file, like
-- 330). Applied live Oct 21 08:2x UTC. Re-runnable: once it reads 60 there's nothing to change.
do $$
declare d text := pg_get_functiondef('public.mod_guard(text, uuid, text)'::regprocedure);
begin
  if position('when ''unban'' then 10 ' in d) > 0 then
    execute replace(d, 'when ''unban'' then 10 ', 'when ''unban'' then 60 ');
  elsif position('when ''unban'' then 60 ' in d) = 0 then
    raise exception 'mod_guard: unban limit not found, check the function by hand';
  end if;
end $$;
