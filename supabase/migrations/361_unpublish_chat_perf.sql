-- 361: chat_perf back to test (Antic, Oct 21 13:07 UTC): people reported the chat scrolling up on its own every 10-20 s in
-- DMs and servers since it was published (338). Its rows with a guessed height (content-visibility) and the window
-- trim are the only scroll changes of that day; find the cause on the test server before publishing again. Data only.
update public.feature_flags set mode = 'test' where key = 'chat_perf';
