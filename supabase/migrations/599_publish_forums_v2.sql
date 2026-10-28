-- 599: Discussions v2 published to everyone (Antic, Oct 27: "publish all on release", after he applied 595). Data only. Applied live 17:25 UTC.
update public.feature_flags set mode = 'everyone' where key = 'forums_v2';
