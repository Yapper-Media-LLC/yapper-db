set lock_timeout = '3s';
-- 274: warnings count for 3 days instead of 90 (Antic, Oct 19: "nerf the warn system", 471 people were limited).
-- Same rule otherwise: 1 active warning = limited, 2 = very limited, 3+ = suspended. Patched in place in every
-- function that used the 90 day window. Re-runnable (the second run finds nothing to change).
do $$
declare f text; d text;
begin
  foreach f in array array['public.standing_tier(uuid)', 'public.my_standing()', 'public.my_standing_proof()', 'public.my_standing_proof_images()'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(f::regprocedure);
    if position('interval ''90 days''' in d) = 0 then continue; end if;
    execute replace(d, 'interval ''90 days''', 'interval ''3 days''');
  end loop;
end $$;
reset lock_timeout;
