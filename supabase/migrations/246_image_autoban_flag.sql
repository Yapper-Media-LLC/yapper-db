-- 246: switch for automatic image bans (lib/server/media.ts scanStored). Starts "off" (Antic, Oct 18: too many
-- false bans even with the Claude check): a blocked picture is still blocked and taken down, but the person is not
-- banned. Someone who keeps getting blocked lands in the Mod Center queue (one report a day) and gets an hour's
-- pause on uploads. Sexual content with someone who looks under 18 still bans straight away whatever this says.
-- "everyone" brings the old auto bans back. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers)
values ('image_autoban', 'Automatic image bans', 'Ban people automatically when the image check blocks their pictures. Off: they go to the Mod Center queue instead (minors always ban)', 'off', '{}')
on conflict (key) do nothing;
