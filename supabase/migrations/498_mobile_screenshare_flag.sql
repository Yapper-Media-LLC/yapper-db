-- 498: flag mobile_screenshare (test: Antic + HQ test server). Screen share on phones: the Android app shares through
-- its own plugin (mobile/android ScreenSharePlugin.kt joins the call as `<user id>:screen`, app/api/livekit-token
-- screen: true checks this flag), and phones that can't share get a dimmed button saying where it works instead of a
-- button that did nothing (Android browsers). Client: lib/voice.ts shareSupport, lib/native.ts. Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mobile_screenshare', 'Screen share on phones', 'Android app shares the screen natively; phones that can''t share say where it works', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
