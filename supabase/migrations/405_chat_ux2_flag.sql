-- 405: flag chat_ux2 (test): chat polish, batch 2. The "New" line at the first unread message in both looks (and at
-- the top when the backlog is longer than the loaded page); your scroll place in a chat is kept while you look at
-- another one; a timed-out member sees a countdown bar instead of typing and failing; "Copy message link" in the
-- message menu, and such links show as a jump chip. Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('chat_ux2', 'Chat polish 2', 'New line in both looks, scroll place kept per chat, timeout countdown in the composer, copy message link', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
