-- 169: "You're timed out until 10:57 UTC" had no date and only UTC (14-17 Oct bug reports: a 1-day timeout
-- read like it ended today, and people outside UTC couldn't tell when it ends).
--  * The send guards and the voice ticket now say "until 2026-10-17 10:57 UTC". The app turns that into the
--    reader's own date and time (lib/supabase.ts localizeUtcTimes); older apps at least show the date.
--  * message_automod (site timeouts), block_server_timeouts (server timeouts) and voice_ticket (both, for calls).
-- Patches the live function bodies (only the time format changes), so other changes to them are kept.
-- Raises if a line to patch isn't found (and isn't already patched), so a failed patch is never silent. Re-runnable.

do $$ declare d text; n int; begin
  -- Site timeout on messages.
  d := pg_get_functiondef('public.message_automod()'::regprocedure);
  if position('to_char(mu at time zone ''UTC'', ''HH24:MI UTC'')' in d) > 0 then
    d := replace(d, 'to_char(mu at time zone ''UTC'', ''HH24:MI UTC'')', 'to_char(mu at time zone ''UTC'', ''YYYY-MM-DD HH24:MI "UTC"'')');
    execute d;
  elsif position('YYYY-MM-DD HH24:MI "UTC"' in d) = 0 then
    raise exception '169: message_automod timeout text not found, patch not applied';
  end if;

  -- Server timeout on messages.
  d := pg_get_functiondef('public.block_server_timeouts()'::regprocedure);
  if position('to_char(u at time zone ''UTC'', ''HH24:MI UTC'')' in d) > 0 then
    d := replace(d, 'to_char(u at time zone ''UTC'', ''HH24:MI UTC'')', 'to_char(u at time zone ''UTC'', ''YYYY-MM-DD HH24:MI "UTC"'')');
    execute d;
  elsif position('YYYY-MM-DD HH24:MI "UTC"' in d) = 0 then
    raise exception '169: block_server_timeouts timeout text not found, patch not applied';
  end if;

  -- Joining a call while timed out.
  d := pg_get_functiondef('public.voice_ticket(uuid)'::regprocedure);
  n := 0;
  if position('to_char(p.muted_until at time zone ''UTC'', ''HH24:MI'')' in d) > 0 then
    d := replace(d, 'to_char(p.muted_until at time zone ''UTC'', ''HH24:MI'')', 'to_char(p.muted_until at time zone ''UTC'', ''YYYY-MM-DD HH24:MI'')');
    n := n + 1;
  end if;
  if position('to_char(until_ts at time zone ''UTC'', ''HH24:MI'')' in d) > 0 then
    d := replace(d, 'to_char(until_ts at time zone ''UTC'', ''HH24:MI'')', 'to_char(until_ts at time zone ''UTC'', ''YYYY-MM-DD HH24:MI'')');
    n := n + 1;
  end if;
  if n > 0 then execute d; end if;
  -- Both voice lines must carry the date now (already patched counts); anything else means the text moved.
  if (length(d) - length(replace(d, '''YYYY-MM-DD HH24:MI''', ''))) / length('''YYYY-MM-DD HH24:MI''') < 2 then
    raise exception '169: voice_ticket timeout text not found, patch not applied';
  end if;
end $$;
