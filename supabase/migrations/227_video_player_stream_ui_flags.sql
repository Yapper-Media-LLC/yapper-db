-- Our own video player (chat videos and /tutorials) and the Discord-style screen share view. Client only.
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('video_player', 'Video player', 'Our own video player for chat videos and tutorials: seek, volume, fullscreen, download.', 'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}'),
  ('stream_ui', 'Screen share view', 'Discord style stream view: big stream with people under it, controls on hover, fullscreen, quality picker.', 'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
