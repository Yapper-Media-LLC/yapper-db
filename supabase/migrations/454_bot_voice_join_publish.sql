-- 454: bot_voice_join published to everyone (Antic, Oct 23): bots can join voice and play audio (music bots, 453).
-- Data only, re-runnable. Needs 453 applied first (the flag row is made there).
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'bot_voice_join' and mode <> 'everyone';
