-- 598: AI noise suppression published to everyone (Antic, Oct 27: "publish all on release"). Data only. Applied live 17:19 UTC.
update public.feature_flags set mode = 'everyone' where key = 'noise_suppression';
