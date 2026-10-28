-- 471: Shard quests and Plus 1.5x published to everyone (Antic, Oct 24, 18:59 UTC). Data only, no schema reload.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'shard_quests' and mode <> 'everyone';
