-- 333: chat_perf (test): message rows off screen skip style/layout/paint (content-visibility), and a chat scrolled
-- far up drops back to its newest 60 rows once you're at the bottom again. A user's chat froze for ~12 s after
-- scrolling up through a long history (600 rows, ~18,000 elements on the page). All client side; this is just the
-- flag row. Data only, no schema change. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('chat_perf', 'Chat: lighter long chats', 'Long chats you scrolled up through stay fast: rows off screen are skipped and the chat trims back when you return to the bottom.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;
