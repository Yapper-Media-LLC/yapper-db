-- 395: flag profile_popcard (test): PR #70's profile side panel (mutual friends/servers next to the profile card) and
-- the member-list mini card on left-click. Its own flag because ui_refresh is already on for everyone. Client only
-- (ProfileCard.tsx, MemberList.tsx, MiniProfileCard.tsx). Test: Antic and the test server. Only a row, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('profile_popcard', 'Profile side panel + mini card', 'Mutual friends/servers panel next to the profile card, and a small profile card when you click someone in the member list', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
