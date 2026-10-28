-- 341: publish creator_badges (340) to everyone (Antic, Oct 21). Data only, no schema change. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'creator_badges';
