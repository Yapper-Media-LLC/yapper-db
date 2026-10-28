-- 548: mod_limit_boost published to everyone (547). Antic said publish on Oct 26 2026. Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'mod_limit_boost' and mode <> 'everyone';
