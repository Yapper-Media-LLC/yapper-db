-- Your server list order (profiles.server_order) is the list of every server you're in, private ones too.
-- It went out with other people's profile rows: bootstrap's profiles[] (your DM partners), channel_messages and
-- channel_messages_since (every author in a channel you read), and plain REST (/rest/v1/profiles?select=server_order
-- for anyone, column granted to authenticated with a `using (true)` select policy). Bug report Oct 23.
--
-- This file: the four definer functions return server_order only on your own row (null for everyone else).
-- Safe to apply any time (old and new app builds read only their own order). The REST half is 422, which must
-- wait until the app build that stops selecting server_order (PROFILE_COLS) is live and the realtime server's
-- profileCache.mjs is redeployed, or every older tab's profile reads fail.

do $$
declare
  fn text;
  f text;
  old_part text := 'tag, server_order, shown_badge';
  new_part text := 'tag, case when profiles.id = (select auth.uid()) then server_order end as server_order, shown_badge';
begin
  foreach fn in array array['bootstrap_fast', 'bootstrap_v1', 'channel_messages', 'channel_messages_since'] loop
    -- Every overload; none on test databases.
    for f in select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = fn loop
      if position(new_part in f) > 0 then continue; end if; -- already patched
      if position(old_part in f) = 0 then raise exception '421: % changed, patch its server_order by hand', fn; end if;
      execute replace(f, old_part, new_part);
    end loop;
  end loop;
end $$;
