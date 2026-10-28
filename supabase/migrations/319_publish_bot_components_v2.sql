-- 319: publish bot_components_v2 (315) to everyone (Antic, Oct 20). Data only, no schema change. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'bot_components_v2';
