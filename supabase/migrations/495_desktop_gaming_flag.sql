-- 495: flag desktop_gaming (applied live Oct 24 08:27 UTC under its old number 457; renumbered past numbers other chats took) (test) and the desktop update bar for everyone.
-- desktop_gaming (needs desktop app 1.1.0+, desktop/): push to talk, mute and deafen keys that work while a game has
-- focus (a low-level key hook in the app, on only during a call), Idle from the computer's own idle time instead of
-- the page's, Settings -> Desktop app (start with Windows, start in the tray, close to tray or quit, hardware
-- acceleration, "Playing" on/off and your own games added from the running programs), a real pop-out window for a
-- stream (document picture-in-picture). lib/hotkeys.ts, lib/status.ts, components/DesktopSettings.tsx, StreamStage.tsx.
-- desktop_update_bar (1.0.3+): "A new version is ready, restart to update" was in test since it shipped; on for everyone.
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('desktop_gaming', 'Desktop app for gamers', 'Push to talk and mute keys that work inside games, no Idle mid-game, Desktop app settings, pop-out stream window (app 1.1.0+)', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'desktop_update_bar' and mode <> 'everyone';
