-- Banned people couldn't delete their account (GDPR erasure) ("Your account is banned from Yapper").
-- Deleting auth.users cascades, and some foreign keys are ON DELETE SET NULL (channels.created_by,
-- messages.pinned_by, profiles.server_tag, ...). Those cascade UPDATEs run as the leaving user, so the
-- not_site_banned trigger refused them and the whole delete rolled back.
--
-- Fix: delete_my_account marks the transaction with yapper.deleting_account = the user's id (local to the
-- transaction, after the password check and keep_ban_leftovers), and not_site_banned lets that user's rows
-- through only while it's set. set_config isn't reachable over the API, same as yapper.bot.
--
-- Both functions have drifted from their migrations (standing guards etc.), so they're patched in place.
-- If either function is re-created later, re-apply 306 (it skips itself once applied).

set lock_timeout = '3s';

do $$
declare src text; out text;
begin
  src := pg_get_functiondef('public.not_site_banned()'::regprocedure);
  if position('yapper.deleting_account' in src) = 0 then
    out := replace(src, E'begin\n  if auth.uid() is not null and public.is_site_banned(auth.uid()) then',
      E'begin\n  -- Account deletion (delete_my_account, 306): cascade updates run as the leaving user.\n'
      || E'  if current_setting(''yapper.deleting_account'', true) = auth.uid()::text then return coalesce(new, old); end if;\n'
      || E'  if auth.uid() is not null and public.is_site_banned(auth.uid()) then');
    if out = src then raise exception '306: not_site_banned marker not found'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.delete_my_account(text)'::regprocedure);
  if position('yapper.deleting_account' in src) = 0 then
    out := replace(src, E'  perform public.keep_ban_leftovers(uid);\n',
      E'  perform public.keep_ban_leftovers(uid);\n'
      || E'  perform set_config(''yapper.deleting_account'', uid::text, true);\n');
    if out = src then raise exception '306: delete_my_account marker not found'; end if;
    execute out;
  end if;
end $$;
