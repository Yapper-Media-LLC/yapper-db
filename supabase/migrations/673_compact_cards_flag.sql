-- 673: flag for shorter profile cards (components/ProfileCard.tsx, MiniProfileCard.tsx, DmProfileDock.tsx,
-- CompactMutuals.tsx): mutual friends and servers as one line that opens the list, artist creations one row with
-- "See all", long role and link lists capped with "+n more", tighter paddings. Test mode: HQ test server and Antic.
-- Data only, no schema reload.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('compact_cards', 'Compact profile cards', 'Shorter profile cards: mutuals on one line, one row of creations with See all, long role and link lists capped with +n more, tighter spacing.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
