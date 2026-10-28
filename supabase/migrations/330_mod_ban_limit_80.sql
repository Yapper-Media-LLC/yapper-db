-- 330: moderators may ban 80 people an hour (Antic, Oct 20 evening: "higher ban limits by 2x", from the original 40).
-- 318 already raised it 40 -> 60 during the raid; this takes it from either to 80. mod_guard counts the last hour of
-- mod_log, so a mod who was at the limit can ban again as soon as this is in. Patches only the ban number in the live
-- function (its full text lives in no migration file). Re-runnable: once it reads 80 there's nothing to change.
do $$
declare d text := pg_get_functiondef('public.mod_guard(text, uuid, text)'::regprocedure);
begin
  if position('when ''ban'' then 40 ' in d) > 0 then
    execute replace(d, 'when ''ban'' then 40 ', 'when ''ban'' then 80 ');
  elsif position('when ''ban'' then 60 ' in d) > 0 then
    execute replace(d, 'when ''ban'' then 60 ', 'when ''ban'' then 80 ');
  elsif position('when ''ban'' then 80 ' in d) = 0 then
    raise exception 'mod_guard: ban limit not found, check the function by hand';
  end if;
end $$;
