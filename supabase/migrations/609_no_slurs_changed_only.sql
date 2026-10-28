-- 609: no_slurs() only checks columns that actually change on UPDATE.
-- Mod Center "Reset profile" on someone whose username AND bio held a slur, with only the name ticked, failed with
-- "That contains a slur": mod_reset_profile's one UPDATE lists bio in its SET (bio = bio), so profiles_no_slurs
-- (UPDATE OF username, bio) fired and refused the row over the untouched bio. Same trap for a user saving their
-- profile with old text the filter has since learned to catch. New or edited text is still checked as before;
-- INSERTs check every column. Same shape as no_bad_names(). Body otherwise identical to live (Oct 27).

create or replace function public.no_slurs()
returns trigger
language plpgsql
set search_path to 'public', 'extensions'
as $function$
declare
  col text;
  val text;
begin
  foreach col in array tg_argv loop
    val := to_jsonb(new) ->> col;
    if val is not null
       and (tg_op = 'INSERT' or val is distinct from (to_jsonb(old) ->> col))
       and public.has_slur(val) then
      raise exception 'That contains a slur, so it wasn''t sent. Keep it respectful.'
        using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$function$;
