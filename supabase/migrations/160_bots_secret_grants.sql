-- 160: bots secrets were readable by every signed-in user.
-- 103 meant to hide token_hash / token_prefix / webhook_secret with column grants, but the schema's default privileges
-- had already granted the whole table to anon and authenticated, so the column grants did nothing. Any user could
-- `select token_hash, webhook_secret from bots` for every public bot (and webhook_url, the owner's own server).
-- Fix: take away the table grants, grant only the public columns back, and let owners read their webhook_url via an RPC.
-- Server code uses the service role and is not affected. Re-runnable.

revoke all on public.bots from anon, authenticated;

grant select (id, owner_id, name, tag, description, category, public, avatar_path, presence, posts,
              created_at, last_used_at, last_poll_at, last_event_at, submitted_at, verified_at, review_note)
  on public.bots to authenticated;

-- Owner-only private bits for the developer page.
create or replace function public.my_bot_hooks()
returns table (id uuid, webhook_url text)
language sql stable security definer set search_path = public as $$
  select b.id, b.webhook_url from public.bots b where b.owner_id = (select auth.uid());
$$;
revoke all on function public.my_bot_hooks() from public, anon;
grant execute on function public.my_bot_hooks() to authenticated;

-- Same lockdown for two server-only tables that had no policies (RLS already hid every row, this is belt and braces).
do $$ begin
  if to_regclass('public.pending_verifications') is not null then
    execute 'revoke all on public.pending_verifications from anon, authenticated';
  end if;
  if to_regclass('public.media_migrate_runs') is not null then
    execute 'revoke all on public.media_migrate_runs from anon, authenticated';
  end if;
end $$;
