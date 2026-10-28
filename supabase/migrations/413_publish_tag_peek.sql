-- 413: tag_peek published to everyone (staff-only in the UI anyway). Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'tag_peek';
