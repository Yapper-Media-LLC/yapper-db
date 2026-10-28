-- 377: publish deco_fit (Line it up / Fix it for community decorations) to everyone. Antic said publish, Oct 21. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'deco_fit';
