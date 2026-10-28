-- 577: spam-bot cleanups stop tripping the mod limits.
--
-- Oct 27 02:58 UTC head mod Tripex (2o) was paused automatically while cleaning up a spam-bot wave: 58 message
-- deletes, 2 bans and a purge in 10 minutes, 59 of them on accounts under 2 days old. The burst guard (565) counted
-- every row the same, so a spam sweep looked like a rogue mod; and the delete cap (60 an hour) would have stopped him
-- two deletes later anyway.
-- 1. mod_burst_check: removal actions (delete, ban, timeout, purge, warn) on accounts under 3 days old don't count
--    toward the 60 in 10 minutes / 200 an hour. Everything else still counts, on any account: unbans, verifications,
--    badges, bot reviews, decorations (giving things to fresh alts stays inside the burst budget).
-- 2. mod_guard: message deletes and purges on accounts under 3 days old get 4x the hourly cap (240 / 80 at 1x boost).
--    Bans, timeouts and warns keep their caps (80 / 60 / 60), so a sweep through new real users stays bounded.
-- Both patched in place on the live text (one condition each; each anchor must match exactly once). Re-runnable.

set lock_timeout = '3s';

do $$
declare f text;
  old_line constant text := 'and action not in (''auto_suspended'', ''mod_limit_boost'', ''badge_auto'');';
  new_line constant text := 'and action not in (''auto_suspended'', ''mod_limit_boost'', ''badge_auto'')'
    || chr(10) || '     -- 577: removals on accounts under 3 days old (spam-bot cleanups) don''t count; mod_guard''s hourly caps still do.'
    || chr(10) || '     and not (action in (''delete'', ''ban'', ''timeout'', ''purge'', ''warn'')'
    || chr(10) || '              and exists (select 1 from public.profiles p where p.id = mod_log.target_id and p.created_at > now() - interval ''3 days''));';
begin
  if to_regprocedure('public.mod_burst_check()') is null then return; end if; -- test databases without 565
  f := pg_get_functiondef('public.mod_burst_check()'::regprocedure);
  if position('-- 577:' in f) > 0 then return; end if; -- already patched
  if (length(f) - length(replace(f, old_line, ''))) / length(old_line) <> 1 then
    raise exception '577: mod_burst_check changed, patch the new-account check by hand';
  end if;
  -- The new line names the table (mod_log.target_id): only valid while the count reads mod_log without an alias.
  if f !~ 'from public\.mod_log\s+where actor = me' then
    raise exception '577: mod_burst_check''s mod_log query changed, patch by hand';
  end if;
  execute replace(f, old_line, new_line);
end $$;

do $$
declare f text;
  old_line constant text := '  lim := ceil(lim * public.mod_limit_boost())::int;';
  new_line constant text := '  -- 577: deletes and purges of brand-new accounts (spam waves) get 4x room; bans, timeouts and warns don''t.'
    || chr(10) || '  if action in (''delete'', ''purge'') and target is not null'
    || chr(10) || '     and exists (select 1 from public.profiles p where p.id = target and p.created_at > now() - interval ''3 days'') then'
    || chr(10) || '    lim := lim * 4;'
    || chr(10) || '  end if;'
    || chr(10) || old_line;
begin
  if to_regprocedure('public.mod_guard(text,uuid,text)') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.mod_guard(text,uuid,text)'::regprocedure);
  if position('-- 577:' in f) > 0 then return; end if; -- already patched
  if (length(f) - length(replace(f, old_line, ''))) / length(old_line) <> 1 then
    raise exception '577: mod_guard changed, patch the new-account cap by hand';
  end if;
  execute replace(f, old_line, new_line);
end $$;

reset lock_timeout;
