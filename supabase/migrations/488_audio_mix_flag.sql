-- 488 (applied live as 486_audio_mix_flag, renamed): flag audio_mix (test: Antic + HQ test server). On iPhones the page's sound engine took over the phone's audio on
-- every tap, so music from other apps stopped while Yapin' was open (report 3d91ed9c). With the flag on, Safari's
-- navigator.audioSession is 'ambient' (pings mix with music) and back to 'auto' during calls and voice messages.
-- Client only (lib/notify.ts, components/App.tsx, components/VoiceRecorder.tsx). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('audio_mix', 'Pings mix with music on iPhone', 'Safari audio session set to ambient outside calls so other apps keep playing', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
