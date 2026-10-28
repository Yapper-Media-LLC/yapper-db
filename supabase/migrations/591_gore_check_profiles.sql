-- 591: gore check for server icons, and avatars and banners from accounts under 3 days old (flag gore_check_profiles, test).
-- Data only (one flag row): no schema change, safe to apply any time. The check is goreWanted in lib/server/media.ts.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gore_check_profiles', 'Gore check for icons and new profiles',
        'Server icons, and profile pictures and banners from accounts under 3 days old, also get the gore and self-harm check.',
        'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
