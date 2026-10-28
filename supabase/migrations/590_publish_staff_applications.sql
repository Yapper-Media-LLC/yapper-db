-- 590: flag staff_applications published to everyone (Antic said "publish" Oct 27). Data only, re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'staff_applications' and mode <> 'everyone';
