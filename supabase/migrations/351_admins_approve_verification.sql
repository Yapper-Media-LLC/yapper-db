-- 351: only admins can approve a verification request (Oct 21, Antic). After 350 a moderator still could approve a
-- request from their own alt account. Moderators can still reject a request or ask for proof, so they keep sorting
-- the queue; the approve itself (which gives the verified badge) is admins only. Patches the live
-- review_verification after 350's own-request check. Re-runnable.
do $$
declare
  d text := pg_get_functiondef('public.review_verification(uuid,boolean,text)'::regprocedure);
  anchor constant text := 'raise exception ''You can''''t review your own verification. Ask another moderator.'';
  end if;';
begin
  if position('Only admins can approve' in d) > 0 then return; end if;
  if position(anchor in d) = 0 then raise exception '351: review_verification changed (needs 350 first), patch it by hand'; end if;
  execute replace(d, anchor, anchor || E'\n  if approve and not public.is_site_admin() then\n    raise exception ''Only admins can approve verifications. Ask for proof or leave it for an admin.'';\n  end if;');
end $$;
