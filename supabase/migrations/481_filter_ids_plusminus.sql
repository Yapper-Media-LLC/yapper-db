-- 481: word filter fixes from the Oct 24-25 reports. NOT applied (database freeze Oct 25).
--
-- 1. "N±GGA" got through: ± wasn't one of the masking symbols (* # § ...), so the masked reading never ran.
--    ± × ÷ + ° are masks now, in has_slur_plain (patched by exact text from the live definition, read Oct 25, which
--    still matches 430) and in the app's copy (lib/filter.ts MASK). The masked reading already runs on any "." or "!",
--    so this doesn't open a new kind of false positive.
-- 2. has_hate (live, made via MCP, no file) looks for 14 88 anywhere a digit doesn't touch it. Ids and colour codes
--    are hex, so a role ping or custom emoji in a reaction-roles message (<@&...a1488f...>) or a colour like #fa1488
--    read as "1488" and the message was refused as a Nazi slogan. Now id tokens and #rrggbb(aa) colours are
--    blanked before that one test (same idea as the IDS rule in lib/filter.ts). Everything else in has_hate is the
--    live text unchanged (read Oct 25); the invisible-character class is copied as is (literal characters).
--    Only ids inside our own tokens (<@id>, <@&id>, <#id>, <:name:id>) are blanked, not bare hex: a bare run like
--    "1488aaaabbbb..." is something people see, so it stays blocked.
--
-- Re-runnable. Functions only (DDL, quiet hours).

set lock_timeout = '2s';

-- ---------- 1: more masking symbols ----------
do $$
declare d text; n_hits int;
  anchor text := $a$[*#@$%&!?_.\-§¤~^•·¡¿]$a$;
  repl text := $a$[*#@$%&!?_.\-§¤~^•·¡¿±×÷+°]$a$;
begin
  d := pg_get_functiondef('public.has_slur_plain(text)'::regprocedure);
  if position('¡¿±×÷+°]' in d) > 0 then return; end if; -- already patched
  n_hits := (length(d) - length(replace(d, anchor, ''))) / length(anchor);
  if n_hits <> 2 then raise exception 'has_slur_plain changed: expected the mask class 2 times, found %. Read its live text again', n_hits; end if;
  execute replace(d, anchor, repl);
end $$;

-- ---------- 2: ids and colours aren't 1488 ----------
CREATE OR REPLACE FUNCTION public.has_hate(t text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select t is not null and (
       t ~ '[卐卍࿕࿖࿗࿘]'
    or translate(regexp_replace(public.slur_text(t), '[^a-z]', '', 'g'), 'l', 'i')
         ~ '(heiihitier|heiihtier|siegheii|seigheii)'
    or regexp_replace(
         regexp_replace(t, '[­̀-ͯ​-‏⁠﻿]', '', 'g'),
         -- 481: uuids (role pings, custom emojis), colour codes and long hex runs aren't numbers.
         '<(@&?|#|a?:[A-Za-z0-9_]{2,32}:)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}>|#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?(?![0-9a-zA-Z])',
         ' ', 'g')
         ~ '(^|[^0-9.,$€£#])14[ /_-]?88($|[^0-9%]|[.,]($|[^0-9]))'
  );
$function$;
