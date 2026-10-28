-- Second opinion on flagged pictures (lib/server/imageReview.ts): before the local checker's refusal sticks,
-- Claude looks at the picture; only "explicit" (or suggestive as a profile picture) is refused, and one picture
-- bans only when Claude is sure. Needs ANTHROPIC_API_KEY in Vercel. Test mode: Antic's uploads only.
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('image_review', 'Image second opinion', 'Pictures the image check flags are double-checked by Claude before they are refused or anyone is banned', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
