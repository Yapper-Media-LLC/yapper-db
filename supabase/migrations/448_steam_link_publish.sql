-- 448: Steam on profiles published to everyone (flag steam_link, from 447). Data only, re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'steam_link';
