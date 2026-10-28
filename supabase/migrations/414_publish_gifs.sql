-- 414: GIF picker (flag gifs) published to everyone: the KLIPY key is on their production tier since Oct 23.
-- Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'gifs';
