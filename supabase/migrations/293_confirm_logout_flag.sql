-- 293: flag for "ask before logging out" (the log out button next to Settings in the user bar). Client only, so this
-- is just the flag row. Test mode like the other test flags: the Yapper test server and Antic's account. Re-running
-- never changes a flag an admin has already moved.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('confirm_logout', 'Confirm log out', 'The log out button asks "Log out?" first, so a mis-click does not sign you out', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
