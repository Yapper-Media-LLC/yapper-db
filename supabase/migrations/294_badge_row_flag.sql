-- 294: flag for showing every badge on the profile card as a row of small icon tiles (hover for the name), instead
-- of only the one picked badge as a labelled pill. Client only, so this is just the flag row. Test mode like the other
-- test flags: the Yapper test server and Antic's account. Re-running never changes a flag an admin has already moved.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('badge_row', 'Badge row on profiles', 'Profile cards show all of someone''s badges as small icon tiles', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
