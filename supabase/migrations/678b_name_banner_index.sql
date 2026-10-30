-- 678b: who wears which community name banner (678): wearer counts, popular order, takedowns. Only 'c:' rows, so it
-- stays tiny. Concurrently, so profile reads and writes don't wait while it scans profiles (~115k rows): run on its
-- own right after 678, outside a transaction (SQL editor, one statement).
create index concurrently if not exists profiles_name_banner_idx on public.profiles (name_banner) where name_banner like 'c:%';
