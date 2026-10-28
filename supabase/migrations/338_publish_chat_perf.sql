-- 338: publish chat_perf (333) to everyone (Antic, Oct 21). Data only, no schema change. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'chat_perf';
