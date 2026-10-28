-- 546: forwarded messages stop counting as mentions in the Mentions inbox and the @ badge (bug reports e7102392,
-- e29928e2). A forward starts with the mark "↪ Forwarded" and a new line (components/ForwardDialog.tsx FORWARD_MARK,
-- lib/mentions.ts isForwarded); the live app and the broadcast_message_change notice already skip those, but
-- my_mentions (the inbox) and unread_counts_for (badges on load) didn't, so forwarding a message that pinged
-- someone pinged them again. Typing the mark by hand doesn't make a forward (the composer defangs it).
-- Both functions are patched in place on their live text (one condition each); nothing else changes. Re-runnable.
-- unread_counts_v1 has its own copy but only runs with fast_startup off, and that flag is 'everyone' (checked Oct 26).

set lock_timeout = '3s';

do $$
declare f text;
  -- my_mentions: the first filter of the mentions lateral (the replies part is left as is: a forward isn't a reply).
  old_line constant text := 'and (strpos(x.content, ''<@'') > 0 or strpos(x.content, ''@everyone'') > 0)';
  new_line constant text := old_line || ' and not starts_with(x.content, chr(8618) || '' Forwarded'' || chr(10))';
begin
  if to_regprocedure('public.my_mentions(integer)') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.my_mentions(integer)'::regprocedure);
  if position('chr(8618)' in f) > 0 then return; end if; -- already patched
  -- Exactly once, or the replace would be wrong.
  if (length(f) - length(replace(f, old_line, ''))) / length(old_line) <> 1 then
    raise exception '546: my_mentions changed, patch the forward check by hand';
  end if;
  execute replace(f, old_line, new_line);
end $$;

do $$
declare f text;
  -- unread_counts_for: the whole mentions filter is skipped for a forward (it has no reply_to either).
  old_open constant text := '(count(*) filter (where f.content like ''%<@''';
  new_open constant text := '(count(*) filter (where not starts_with(coalesce(f.content, ''''), chr(8618) || '' Forwarded'' || chr(10)) and (f.content like ''%<@''';
  old_close constant text := 'pm.author_id = (select auth.uid())))))::int as mentions';
  new_close constant text := 'pm.author_id = (select auth.uid()))))))::int as mentions';
begin
  if to_regprocedure('public.unread_counts_for(public.channels[])') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.unread_counts_for(public.channels[])'::regprocedure);
  if position('chr(8618)' in f) > 0 then return; end if; -- already patched
  if (length(f) - length(replace(f, old_open, ''))) / length(old_open) <> 1
     or (length(f) - length(replace(f, old_close, ''))) / length(old_close) <> 1 then
    raise exception '546: unread_counts_for changed, patch the forward check by hand';
  end if;
  execute replace(replace(f, old_open, new_open), old_close, new_close);
end $$;
