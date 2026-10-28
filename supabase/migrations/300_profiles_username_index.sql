-- 300: a plain index on profiles.username (Oct 20).
-- After username_taken() became server-only (280), scripts switched to the REST API as signed-in users:
-- GET /rest/v1/profiles?select=id&username=eq.<name>, about 175k a day from a few IPs (python-requests).
-- The only username indexes are on lower(username), so every one of those read the whole table (~1k pages, 17 ms):
-- profiles was the most-read table on the database (Supabase support, Oct 19: ~800 GB of reads a day on 29 MB).
-- With this index an exact match is a few pages. Usernames are unique case-insensitively already
-- (profiles_username_lower_idx), so this one doesn't need to be unique. Re-runnable.

set local lock_timeout = '3s'; -- don't queue sign-ups behind a long-held lock; just re-run if it times out
create index if not exists profiles_username_idx on public.profiles (username);
