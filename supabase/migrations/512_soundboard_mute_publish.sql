-- 512: soundboard_mute published to everyone (Antic, Oct 25, after .Autumn and greninja asked for a way to mute the
-- soundboard in HQ). Applied live 13:58 UTC together with 505 (the flag row). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('soundboard_mute', 'Soundboard mute', 'Soundboard volume in Settings, a mute button in the call and muting one person''s sounds', 'everyone',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'soundboard_mute' and mode <> 'everyone';
