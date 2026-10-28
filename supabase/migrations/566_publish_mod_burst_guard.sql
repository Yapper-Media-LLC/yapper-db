-- 566: mod_burst_guard published to everyone (565). Antic said publish on Oct 26 2026. Data only, re-runnable.
-- Apply right after 565 (the flag row comes from 565); in test mode the guard is inert because admins are skipped.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'mod_burst_guard' and mode <> 'everyone';
