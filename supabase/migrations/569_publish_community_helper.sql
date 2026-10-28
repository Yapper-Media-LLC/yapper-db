-- 569: community_helper published to everyone (568). Antic said "push for everyone" on Oct 26 2026. Data only, re-runnable.
-- Apply right after 568 (the flag row and the admin_set_badge patch come from 568).
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'community_helper' and mode <> 'everyone';
