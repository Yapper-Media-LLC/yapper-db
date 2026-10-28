-- 578: publish no_hq_autojoin (Antic: "publish", Oct 27 ~10:10 UTC). Data only, no schema change, safe at any hour.
-- Needs 576 applied first (the flag row and the trigger check live there).
update public.feature_flags set mode = 'everyone' where key = 'no_hq_autojoin';
