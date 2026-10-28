-- 622: flag plus_tenure_badges published to everyone (Antic said "publish the badges" Oct 28, applied live by update). Data only, re-runnable.
update public.feature_flags set mode = 'everyone' where key = 'plus_tenure_badges' and mode <> 'everyone';
