-- 416: gif_ads published to everyone. Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'gif_ads';
