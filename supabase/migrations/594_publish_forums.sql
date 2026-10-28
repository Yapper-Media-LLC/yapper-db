-- 594: forums published to everyone (Antic, Oct 27: "publish the forums"). Data only. Applied live with 593.
update public.feature_flags set mode = 'everyone' where key = 'forums';
