-- 521: level_always published to everyone (Antic, Oct 25): the account level shows on every profile card, 0
-- included, so people find out levels exist. Applied live together with 520 (the flag row). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('level_always', 'Level on every profile', 'Profile cards show the account level even at 0 and 1', 'everyone',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'level_always' and mode <> 'everyone';
