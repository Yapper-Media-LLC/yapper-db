-- 596: flag for AI noise suppression in calls (lib/noise.ts), test mode for Antic. Data only, no schema reload.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('noise_suppression', 'AI noise suppression', 'RNNoise on your mic in calls: removes keyboards, fans and background voices. Switch in Voice & Audio and in the voice bar.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
