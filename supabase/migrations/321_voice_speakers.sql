-- 321: voice_speakers (test): everyone LiveKit has in the call gets a tile, the speaking ring trusts LiveKit over
-- self-reported deafen, mods get "Recently talked" in the call view, and voice tickets only allow mic/camera/screen
-- tracks. All client and ticket side; this is just the flag row. Data only, no schema change. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('voice_speakers', 'Voice: who''s talking', 'Shows everyone who is really in a call and who talked recently, so mods can tell who said what.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;
