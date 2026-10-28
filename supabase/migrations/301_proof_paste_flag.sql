-- 301: flag for pasting screenshots into the warn/ban proof (Ctrl+V after Win+Shift+S). Client only, so this is just
-- the flag row. Test mode like the other test flags: the Yapper test server and Antic's account. Re-running never
-- changes a flag an admin has already moved.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('proof_paste', 'Paste proof screenshots', 'Warn and ban dialogs: Ctrl+V adds a screenshot to the proof', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
