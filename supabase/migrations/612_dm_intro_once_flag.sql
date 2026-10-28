-- 612: flag dm_intro_once (test). An empty DM showed the other person twice in the chat body: the intro (big avatar
-- + name) and the dm_card safety card below it (avatar + name again). With this flag the card drops its avatar, name
-- and box and sits under the intro (components/DmSafetyCard.tsx bare). Data only, no schema reload.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('dm_intro_once', 'DM intro once', 'Empty DMs show the person once: the safety card loses its own avatar, name and box and becomes part of the intro.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
