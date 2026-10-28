-- 388: publish call_ringtones to everyone. Antic said publish, Oct 22. Re-runnable, data only.
update public.feature_flags set mode = 'everyone' where key = 'call_ringtones';
