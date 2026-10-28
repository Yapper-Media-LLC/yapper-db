-- 496: publish the gore check (484) to everyone. Antic, Oct 25. Data only, no schema reload.
update public.feature_flags set mode = 'everyone' where key = 'gore_check';
