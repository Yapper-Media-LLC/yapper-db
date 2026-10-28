-- 619: flag staff_applications published to everyone (Antic said "publish" Oct 27, applied live by update). Data only, re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'staff_applications' and mode <> 'everyone';
