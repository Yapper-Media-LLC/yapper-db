-- 396: publish profile_popcard (395) to everyone: profile side panel with mutuals and the member-list mini card. Data only.
update public.feature_flags set mode = 'everyone' where key = 'profile_popcard';
