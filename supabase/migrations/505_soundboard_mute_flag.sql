-- 505: flag soundboard_mute (test: Antic + HQ test server). A way to stop hearing soundboard clips: a Soundboard volume
-- slider in Settings, Voice & Audio (0 = muted), a quick mute button in the call's soundboard panel, and "Mute their
-- soundboard" in a person's menu in the call. All saved per device in the audio prefs (lib/audio.ts), applied where
-- clips play (lib/sounds.ts playLocally). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('soundboard_mute', 'Soundboard mute', 'Soundboard volume in Settings, a mute button in the call and muting one person''s sounds', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
