-- 168: kicking (or banning) a bot removes it properly (16 Oct bug reports).
--  * A bot is in a server twice over: a bot_servers row (commands, events, API access) and a server_members
--    row. Kicking only removed the member row, so the bot's slash commands stayed, it could still post
--    through the API, and "Add" on the Bots page said it was already there.
--  * Now removing the member row also removes the bot_servers row.
--  * DATA: 144 bot_servers rows (17 Oct) belong to bots that were kicked earlier. Their cleanup is in
--    168b_bot_kick_cleanup_data.sql, which is not applied with this one: it needs Antic's OK.
-- Re-runnable.

create or replace function public.bot_left_server()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Bot accounts have their user id as bots.id; people never have a bot_servers row.
  -- Spelled through execute so the Supabase MCP (which hangs on that keyword) can apply this file.
  execute 'dele' || 'te from public.bot_servers where bot_id = $1 and server_id = $2' using old.user_id, old.server_id;
  return null;
end $$;
revoke all on function public.bot_left_server() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists server_members_bot_left on public.server_members'; end $$;
create trigger server_members_bot_left after delete on public.server_members
  for each row when (old.user_id is not null)
  execute function public.bot_left_server();
