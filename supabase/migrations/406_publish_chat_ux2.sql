-- 406: chat_ux2 published to everyone (405), applied live Oct 22 2026 ~17:40 UTC after Antic tried it on the test
-- server. Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'chat_ux2' and mode <> 'everyone';
