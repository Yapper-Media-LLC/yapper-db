-- 324: publish gif_avatar_still (323) to everyone (Antic, Oct 20). Data only, no schema change. Re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'gif_avatar_still';
