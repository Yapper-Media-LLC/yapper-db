-- 482: "N±GGA" still got through after 481 (checked live Oct 25 right after applying it). has_slur_plain's masked
-- reading runs lower(unaccent(fold_fancy(t))) first, and unaccent turns ± into "+/-" and ÷ into "/". "/" wasn't one
-- of the symbols dropped there, so "n+/-gga" became "n/gga" and didn't match. The PGlite test stubs unaccent, so
-- stage481 passed without seeing it.
-- Now "/" is dropped in that reading too. Only there: the reading still only runs when the raw text has one of the
-- masking symbols (the second class, unchanged), so a plain "a/b" in normal text is never touched.
-- Patched by exact text from the live definition (read Oct 25 after 481). Re-runnable. DDL, quiet hours.

set lock_timeout = '2s';

do $do$
declare d text; n_hits int;
  anchor text := $a$¡¿±×÷+°]+'$a$;
  repl text := $a$¡¿±×÷+°/]+'$a$;
begin
  d := pg_get_functiondef('public.has_slur_plain(text)'::regprocedure);
  if position('¡¿±×÷+°/]+' in d) > 0 then return; end if; -- already patched
  n_hits := (length(d) - length(replace(d, anchor, ''))) / length(anchor);
  if n_hits <> 1 then raise exception 'has_slur_plain changed: expected the removal class once, found %. Read its live text again', n_hits; end if;
  execute replace(d, anchor, repl);
end $do$;

reset lock_timeout;
