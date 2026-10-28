-- 376: flag deco_fit (Oct 21). "Line it up" in the make window for community decorations and effects: size and move
-- a still picture over your avatar before sending it in (baked into a 512x512 PNG in the browser), and "Fix it" on
-- a turned-down one to load it back in. Client only (components/CommunityDecos.tsx). Test: Antic and HQ. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('deco_fit', 'Line up decorations', 'Size and move a decoration before sending it in, and fix a turned-down one', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
