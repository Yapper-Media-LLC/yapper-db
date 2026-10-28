-- Second half of 421: nobody reads profiles.server_order over REST any more, not even their own (bootstrap, a
-- definer, hands you yours). Saving the order still works: it's an UPDATE (column grant kept) with return=minimal.
--
-- APPLY ONLY AFTER: the app build without server_order in PROFILE_COLS (lib/types.ts) has been live for a day, and
-- ops/realtime/profileCache.mjs (same list) is redeployed on the VPS. A tab on an older build asks for
-- server_order in every profile read, and those reads would fail with "permission denied".

revoke select (server_order) on public.profiles from anon, authenticated;
