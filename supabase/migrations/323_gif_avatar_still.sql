-- GIF avatars show a still first frame in lists and move on hover (components/Avatar.tsx, lib/server/avatarStill.ts).
-- Test only until Antic publishes it. Copies of old GIF avatars: Admin → Images → Still copies of GIF avatars.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gif_avatar_still', 'Still GIF avatars', 'GIF avatars stand still in chat, members and DMs and play on hover; profile cards play a small copy', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;
