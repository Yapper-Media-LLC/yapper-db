-- 245: flag for the neutral age screen on sign-up (birth month + year, no age shown, under 13 blocked, nothing saved).
-- Test mode: only on through the link yapper.website/?agescreen=1. "everyone" turns it on for all sign-ups.
-- Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers)
values ('age_screen', 'Age screen on sign-up', 'Ask birth month and year on sign-up and block under 13. Test: only via ?agescreen=1', 'test', '{}')
on conflict (key) do nothing;
