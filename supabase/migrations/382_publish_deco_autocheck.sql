-- 382: publish deco_autocheck (381) to everyone: all staff get the Flagged tab (Antic, Oct 22). Data only, no schema change. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'deco_autocheck';
