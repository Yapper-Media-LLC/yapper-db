-- 639: open decoration uploads again, test group first (flag deco_uploads_open, test: HQ test server + Antic).
-- Uploads were paused by 527 (flag deco_submissions_closed, everyone) and 535 made submit_community_deco refuse too.
-- While deco_uploads_open is on for someone, the pause doesn't apply to them: Make a decoration shows the form (with
-- the "1,800+ live, only the best get in" notice) and submit_community_deco accepts. Everyone else still gets the
-- "enough for now" card.
-- To publish (open for everyone), data only, any time:
--   update public.feature_flags set mode = 'off', updated_at = now() where key = 'deco_submissions_closed';
-- deco_uploads_open can then go off too; it only matters while the pause flag is on.
-- One flag row (data) + submit_community_deco patched in place (function text changes: schema reload, quiet hours).
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('deco_uploads_open', 'Deco uploads: open again',
        'Lets the test group send in decorations while the pause (deco_submissions_closed) is still on. Publish by turning the pause flag off.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

do $$
declare f text;
  old_line constant text := 'if public.feature_on_for_me(''deco_submissions_closed'') then raise exception ''Decoration submissions are paused for now''; end if;';
  new_line constant text := 'if public.feature_on_for_me(''deco_submissions_closed'') and not public.feature_on_for_me(''deco_uploads_open'') then raise exception ''Decoration submissions are paused for now''; end if;';
begin
  if to_regprocedure('public.submit_community_deco(text,text,text)') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.submit_community_deco(text,text,text)'::regprocedure);
  if position('deco_uploads_open' in f) > 0 then return; end if; -- already patched
  if position(old_line in f) = 0 then raise exception '639: submit_community_deco changed, patch the open check by hand'; end if;
  execute replace(f, old_line, new_line);
end $$;
