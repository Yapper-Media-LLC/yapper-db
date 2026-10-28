-- 200: every bot API request looks its bot up by token_hash, which had no index (a scan of all bots each time).
-- Re-runnable. Partial, since hosted-only rows may not have a token.
create unique index if not exists bots_token_hash on public.bots (token_hash) where token_hash is not null;
