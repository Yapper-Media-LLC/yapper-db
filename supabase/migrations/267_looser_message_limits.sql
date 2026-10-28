-- 267: looser message rate limits (Antic, Oct 18): everyone 8 messages in 5 seconds (was 5), accounts under an hour
-- old one message every 2 seconds (was 3), and the same message can go out 3 times a minute (was 2). Patched in
-- place on the live function text (anchored replace, fails loudly if an anchor is missing). Re-runnable.

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.message_raid_guard()'::regprocedure);
  if position('if recent >= 8 then' in d) = 0 then
    n := replace(d, 'if recent >= 5 then', 'if recent >= 8 then');
    if n = d then raise exception '267: message_raid_guard anchor (recent >= 5) not found'; end if;
    d := n;
  end if;
  if position('interval ''2 seconds'' then' in d) = 0 then
    n := replace(d, 'if last_at > now() - interval ''3 seconds'' then', 'if last_at > now() - interval ''2 seconds'' then');
    if n = d then raise exception '267: message_raid_guard anchor (3 seconds) not found'; end if;
    d := replace(n, 'every 3 seconds', 'every 2 seconds');
  end if;
  execute d;

  d := pg_get_functiondef('public.message_automod()'::regprocedure);
  if position('if dup >= 3 then' in d) = 0 then
    n := replace(d, 'if dup >= 2 then', 'if dup >= 3 then');
    if n = d then raise exception '267: message_automod anchor (dup >= 2) not found'; end if;
    execute n;
  end if;
end $$;
