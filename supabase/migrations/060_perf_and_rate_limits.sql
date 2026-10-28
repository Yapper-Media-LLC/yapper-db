-- Bug-hunter fixes, 2026-10-14.
-- * Discover timed out (8s): discover_servers_v2 now counts members in one pass and only runs
--   the expensive name/ban checks on the top candidates (0.5s).
-- * "Search all my servers" timed out on common words: search_messages now uses the word index
--   first, then keeps hits from channels I can read.
-- * Firing the same send request many times at once slipped past slowmode: message_slowmode and
--   message_raid_guard take a per-person advisory lock, and everyone gets 5 messages / 5 seconds.
-- * make_server_template: gen_random_bytes lives in the extensions schema.
-- The function bodies were applied with the Supabase MCP (see the dashboard's migration list:
-- discover_servers_fast, search_messages_gin, message_rate_locks).

alter function public.make_server_template(uuid) set search_path = public, extensions;
