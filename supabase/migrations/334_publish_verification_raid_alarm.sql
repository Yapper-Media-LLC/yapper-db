-- 334: publish server_verification and raid_alarm (Antic, Oct 21). Applied live 08:5x UTC. Row update only, no reload.
update public.feature_flags set mode = 'everyone', updated_at = now() where key in ('server_verification', 'raid_alarm');
