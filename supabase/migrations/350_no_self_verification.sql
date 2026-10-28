-- 350: staff can't review their own verification request (Oct 21). A moderator approved their own "Creator" request
-- and got the verified badge; review_verification only checked is_staff(). Now review_verification,
-- ask_verification_proof and reopen_verification refuse the requester themselves unless they are an admin.
-- Patches each live function right after its "Not found" check (their full text lives in no single migration file,
-- like 330/332). Re-runnable: a function that already has the check is left alone.
do $$
declare
  f text;
  d text;
  anchor constant text := 'if r.id is null then raise exception ''Not found''; end if;';
begin
  foreach f in array array['review_verification(uuid,boolean,text)', 'ask_verification_proof(uuid,text)', 'reopen_verification(uuid,text)'] loop
    d := pg_get_functiondef(('public.' || f)::regprocedure);
    if position('your own verification' in d) > 0 then continue; end if;
    if position(anchor in d) = 0 then raise exception '350: % changed, patch it by hand', f; end if;
    execute replace(d, anchor, anchor || E'\n  if r.user_id = auth.uid() and not public.is_site_admin() then\n    raise exception ''You can''''t review your own verification. Ask another moderator.'';\n  end if;');
  end loop;
end $$;
