-- 671: "You can send 3 suggestions a day. Try again tomorrow" when the 3 were sent yesterday evening (bug 972e512d).
-- The limit is a rolling 24 hours, so "tomorrow" was wrong and people thought it was broken. The message now says the
-- limit is per 24 hours and how long until the next one opens. Only that one line of submit_suggestion changes: the
-- live definition is edited in place, so nothing else in it can drift. Re-runnable.

set lock_timeout = '3s';

do $$
declare
  fn regprocedure := to_regprocedure('public.submit_suggestion(uuid,text,text,text)');
  src text;
  def text;
  old_line constant text := $q$    raise exception 'You can send 3 suggestions a day. Try again tomorrow';$q$;
  new_line constant text := $q$    /* 671: */ raise exception 'You can send 3 suggestions every 24 hours. Your next one opens in %',
      (select case when w < interval '1 hour' then greatest(1, ceil(extract(epoch from w) / 60))::int || ' min'
                   else ceil(extract(epoch from w) / 3600)::int || ' h' end
       from (select min(created_at) + interval '1 day' - now() as w from public.suggestions
             where user_id = uid and created_at > now() - interval '1 day') x);$q$;
begin
  if fn is null then raise exception '671: submit_suggestion is missing'; end if;
  select p.prosrc into src from pg_proc p where p.oid = fn;
  if position('671:' in src) > 0 then return; end if; -- already done
  if position(old_line in src) = 0 then
    raise exception '671: the limit line in submit_suggestion changed since Oct 29, change the message by hand';
  end if;
  def := replace(pg_get_functiondef(fn), old_line, new_line);
  execute def;
  -- Grants as they are live (create or replace keeps them; written down here). Inside the block so a re-run, which
  -- returns early above, doesn't make PostgREST reload its schema for nothing.
  revoke all on function public.submit_suggestion(uuid, text, text, text) from public, anon;
  grant execute on function public.submit_suggestion(uuid, text, text, text) to authenticated, service_role;
end $$;

reset lock_timeout;
