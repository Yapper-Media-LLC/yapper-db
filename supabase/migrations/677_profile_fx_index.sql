-- 677: who wears which community profile effect (672): wearer counts, popular order, takedowns. Only 'p:' rows, so
-- it stays tiny. Concurrently, so profile writes don't wait while it scans profiles (~115k rows): run on its own,
-- outside a transaction (SQL editor, one statement).
create index concurrently if not exists profiles_profile_fx_idx on public.profiles (profile_effect) where profile_effect like 'p:%';
