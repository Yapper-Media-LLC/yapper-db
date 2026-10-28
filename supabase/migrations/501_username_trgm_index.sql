-- 501: trigram index on profiles.username, so `username ilike ...` (with or without %) is an index lookup. Re-runnable.
-- Why (Oct 25): `profiles?select=username&username=ilike.<name>` averaged 1,144 ms x 12,195 calls (13.9k s in 15 h),
-- mostly a username sniper (UA ogu-sniper/3.1, 23.5k requests in 15 min on Oct 24); prefix searches from the app
-- (lib/communityDecos.ts, mod tools) averaged 156 ms. An ilike can't use the btree indexes, so each one read ~85k
-- index entries. With the trigram index it's a few milliseconds whoever asks.
-- Run each statement on its own (SQL editor or execute_sql), never inside a migration transaction: `concurrently`
-- builds without blocking writes to profiles. Afterwards check pg_index.indisvalid is true for the index (a failed
-- concurrent build leaves an invalid one that `if not exists` would skip: then drop it and run again).
create extension if not exists pg_trgm with schema extensions;
create index concurrently if not exists profiles_username_trgm_idx on public.profiles using gin (username extensions.gin_trgm_ops);
