-- 392: flag ui_refresh (Oct 22). Vspcoderz's UI pieces from PR #69 that work on their own: unread-DM bubbles on the
-- rail, the account bar as a floating card, and Save under display name / pronouns / About me in the profile editor.
-- Client only (Rail.tsx, UserBar.tsx, SettingsDialog.tsx). Test: Antic and HQ. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('ui_refresh', 'UI refresh', 'Unread DM bubbles on the rail, floating account card, Save per profile field', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
