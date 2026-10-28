-- 379: two tickets opened at the same moment in one server (a double click, a bot button pressed twice) both passed the
-- "how many open tickets do you have" count and both made the "Tickets" category (6 servers ended up with two).
-- open_ticket now takes a lock per server first, so the second call waits for the first and sees what it made.
-- Patches the live text in place (like 183 did) instead of copying the whole function, so nothing else in it moves.
-- Re-runnable: skipped when the lock line is already there. Only a function body changes (the API schema cache still
-- reloads, like for any function change: apply it in the same go as 378, before 14:00 UTC).
do $do$
declare
  src text;
  old_chk text := $q$  if not public.feature_on('tickets', sid) then raise exception 'Tickets aren''t available here yet'; end if;$q$;
  new_chk text;
begin
  select pg_get_functiondef('public.open_ticket(uuid,text,text)'::regprocedure) into src;
  if position('pg_advisory_xact_lock' in src) = 0 then
    if (length(src) - length(replace(src, old_chk, ''))) <> length(old_chk) then
      raise exception '379: open_ticket lock patch did not match exactly once';
    end if;
    new_chk := old_chk || E'\n  perform pg_advisory_xact_lock(hashtextextended(''open_ticket:'' || sid::text, 0));';
    execute replace(src, old_chk, new_chk);
  end if;
end $do$;
