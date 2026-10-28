-- 318: raid on Oct 20 evening (72 mod bans in an hour, one mod at 39 of 40): site mods get 60 bans an hour (was 40).
-- Antic's call. Patched in place in the live mod_guard (it was edited outside migrations: 40, takedown/purge limits,
-- no auto-pause), so nothing else in it changes. Re-runnable; to go back, swap the two numbers.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.mod_guard(text,uuid,text)'::regprocedure);
  if position('when ''ban'' then 40' in d) > 0 then
    execute replace(d, 'when ''ban'' then 40', 'when ''ban'' then 60');
  elsif position('when ''ban'' then 60' in d) = 0 then
    raise exception 'mod_guard changed since 318 was written: patch it by hand';
  end if;
end $$;
