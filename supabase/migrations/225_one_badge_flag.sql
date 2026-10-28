-- One badge next to your name (flag one_badge): the verified check joins the badge picker in Settings → My Profile,
-- so people show the check OR one badge, plus PLUS if they have it. Stored in profiles.shown_badge ('verified',
-- a badge key, or 'none'); that column already exists (066) and users can already write it. Client only otherwise.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('one_badge', 'One badge', 'Pick one mark next to your name (verified check or a badge). PLUS still shows with it.', 'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
