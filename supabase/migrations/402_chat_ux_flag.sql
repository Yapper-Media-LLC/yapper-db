-- 402: flag chat_ux (test): day-to-day chat polish. A message that arrives while you're scrolled up counts as unread
-- and shows a "N new messages" pill instead of being marked read unseen; Escape closes the side panel, then marks the
-- chat read and jumps to the newest message; Page Up/Down scroll the chat while typing; an Edit pencil in the hover
-- bar; Shift+click Delete skips the confirm. Data only. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('chat_ux', 'Chat polish', 'New-messages pill and read-at-bottom, Escape and Page keys in chat, Edit in the hover bar, Shift+click delete', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
