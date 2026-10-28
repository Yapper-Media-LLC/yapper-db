-- 371: publish plus_moments to everyone (Antic, Oct 21). Data only, no schema change. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'plus_moments';
