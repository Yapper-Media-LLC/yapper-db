-- 442: flag image_thumbs (test): small copies for avatars and chat pictures, so lists stop loading multi-MB originals.
-- Still avatars and chat pictures uploaded with the flag on get "-t" in their name and the scan makes a 160 px / 800 px
-- WebP copy before it says ok (lib/files.ts hasThumb, lib/server/avatarStill.ts makeThumb). Also: a GIF avatar's
-- copies get one more try under ?r=1 before the original (the files domain caches 404s for a month), and Safari's
-- scaled-down PNG is sent when it's smaller than the original. Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('image_thumbs', 'Small picture copies', 'Avatars and chat pictures load a small copy in lists instead of the full-size original (new uploads)', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
