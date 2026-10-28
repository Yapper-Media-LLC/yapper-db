-- Small wins from HQ #suggestions (Oct 18): two new test flags. GIFs move to KLIPY (code only, flag `gifs`
-- already exists). rules_channel and webhooks were published the same day (mode = 'everyone', set live).
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('server_mark_read', 'Mark server as read', 'Right-click a server icon: Mark as read clears every unread channel in it', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}'),
  ('lightbox_arrows', 'Picture viewer arrows', 'Arrows and the left/right keys step through a channel''s pictures in the full-screen viewer', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- Published with this change (Antic, Oct 18).
update public.feature_flags set mode = 'everyone' where key in ('rules_channel', 'webhooks') and mode = 'test';
