-- 452: stream_ui published to everyone (Antic, Oct 23): the Discord style screen share view (big stream with people under
-- it, controls on hover, fullscreen, pop out, quality picker before going live) was in test since 227. Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'stream_ui' and mode <> 'everyone';
