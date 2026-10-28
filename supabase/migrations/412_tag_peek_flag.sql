-- 412: flag tag_peek (test): staff get a "Look inside (staff)" button on the server card that opens from a
-- profile's server tag (components/TagServerCard.tsx). Same peek as the Mod Center's server watch
-- (staff_watch_peek, 215): mods only for flagged or reported servers and public channels, admins any server, every
-- look in the mod log. Asked by Tripex (a seller's private server behind his tag). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('tag_peek', 'Look inside from a tag', 'Staff: a Look inside button on the server card behind a profile tag', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
