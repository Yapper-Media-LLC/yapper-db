-- 314: HQ's suggestion form works in #suggestions too. The channel was renamed from #suggestions-new to #suggestions
-- (Oct 19) and the form only looked for the old name, so it turned back into a normal chat. Either name works now
-- (still only in Yapper HQ). Patched in place; re-runnable.
do $$
declare d text;
begin
  if to_regprocedure('public.submit_suggestion(uuid,text,text,text)') is null then return; end if;
  d := pg_get_functiondef('public.submit_suggestion(uuid,text,text,text)'::regprocedure);
  if position('c.name <> ''suggestions-new''' in d) > 0 then
    d := replace(d, 'c.name <> ''suggestions-new''', 'c.name not in (''suggestions-new'', ''suggestions'')');
    d := replace(d, 'Suggestions go in #suggestions-new in Yapper HQ', 'Suggestions go in #suggestions in Yapper HQ');
    execute d;
  elsif position('''suggestions-new'', ''suggestions''' in d) = 0 then
    raise exception 'submit_suggestion changed since 314 was written: patch it by hand';
  end if;
end $$;
