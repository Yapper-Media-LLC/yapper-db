-- 313: publish bot_share_add (309) to everyone (Antic, Oct 20). Data only, no schema change. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'bot_share_add';
