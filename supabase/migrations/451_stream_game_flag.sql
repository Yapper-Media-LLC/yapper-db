-- 451: flag stream_game (test): screen sharing tuned for games.
-- The share picker asks Game or Text and apps. Game keeps the frame rate when the connection or the computer can't keep
-- up (the picture softens instead of stuttering), uses H.264 so the graphics card encodes it, sends the sound in stereo
-- untouched, and sends a half-size copy too so a viewer on a weak connection gets fewer pixels instead of a frozen
-- picture (viewers pick Auto / Source / Data saver over the stream). A share that died with the connection is started
-- again after the rejoin. Text keeps today's behaviour (sharp text first). lib/voice.ts, components/SharePicker.tsx,
-- components/StreamStage.tsx.
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('stream_game', 'Game screen share', 'Game or Text mode when sharing: smooth 60 fps, H.264, stereo sound, a half-size copy for weak viewers, share restarts after a drop', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
