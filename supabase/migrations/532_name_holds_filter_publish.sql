-- 532: publish deleted_name_hold and name_filter_v2 (530) to everyone (Antic, Oct 26: "publish"). Data only.
update public.feature_flags set mode = 'everyone', updated_at = now()
 where key in ('deleted_name_hold', 'name_filter_v2') and mode <> 'everyone';
