-- 520: flag level_always (test: Antic's test server and Antic). The account level chip on profile cards (full card,
-- mini card, DM profile dock) shows at every level, 0 and 1 included, so people find out levels exist. Off = the chip
-- stays hidden at level 0 like before. Publish with mode 'everyone'. components/AccountLevel.tsx.
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('level_always', 'Level on every profile', 'Profile cards show the account level even at 0 and 1', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
