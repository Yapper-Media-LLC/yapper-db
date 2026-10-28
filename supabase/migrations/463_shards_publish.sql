-- 463: Shards published to everyone (Antic, Oct 24: "publish and make live"). Data only, no schema reload.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'shards' and mode <> 'everyone';
