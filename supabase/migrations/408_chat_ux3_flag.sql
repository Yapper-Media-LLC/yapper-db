-- 408: flag chat_ux3 (test): chat polish, batch 3. Recent emojis (quick reactions in the menu and hover bar, a Recent
-- row in the picker), Escape closes the @ / # / command menus without cancelling the reply and the picked row stays
-- in view, a "+" chip after a message's reactions, a paste too long for a message becomes message.txt, swipe between
-- pictures and down to close in the viewer plus a Download button, and search filters in:#channel, has:kind,
-- before:date, after:date (409). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('chat_ux3', 'Chat polish 3', 'Recent emojis, menu Escape, add-reaction chip, long paste to file, lightbox swipe and download, search filters', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
