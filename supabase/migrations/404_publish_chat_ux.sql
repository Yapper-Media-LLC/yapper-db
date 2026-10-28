-- 404: chat_ux published to everyone (402), applied live Oct 22 2026 ~17:05 UTC after Antic tried it on the test
-- server. Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'chat_ux' and mode <> 'everyone';
