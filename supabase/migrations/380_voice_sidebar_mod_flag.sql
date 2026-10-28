-- 380: flag voice_sidebar_mod (test): right-click someone in a voice channel in the sidebar to mute, move, disconnect
-- or voice-ban them without joining the call (components/VoiceVolumeMenu.tsx). Same rights checks as the voice view
-- (mute_members / move_members and a higher role). Nothing hidden: mods are never invisible in a call. Only a row.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('voice_sidebar_mod', 'Voice mod from sidebar', 'Mods can mute, move, disconnect and voice-ban people from the sidebar without joining the call', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
