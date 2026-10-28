-- 273 slur filter hardening (bug report b3d8d29a). Re-runnable.
-- slur_text is shared by bad_name, webhook_name_ok, the spam and self-harm checks and the auto-ban rule, so it is NOT
-- changed here. Everything below is an extra pass in has_slur, so the filter can only get stricter than it was.
--   1. six_nine_g: a 6 or 9 in the middle of a word is read as "g" (ni99er, ni66er). slur_text turned those digits into
--      a gap, which only caught the word when the digit sat next to its first or last letter. has_slur checks the text
--      as typed (as before) AND with the digits read as g. The reading looks at the text after fold_fancy, so hidden
--      characters and fullwidth / circled digits next to the 6 or 9 don't stop it. Ids that stand alone (a uuid, a cdn
--      hash) are blanked in this reading only: "fa99e7" inside an id would otherwise read as a slur. An id glued to
--      letters is not an id, so a word can't be hidden behind a run of hex.
--   2. The "masked" check (symbols hidden inside a word: re*tard, k*ike) covered two words. It covers every word now.
--   3. Text that uses a right-to-left override (U+202E) to show a word backwards is checked backwards as well. Only
--      the override reverses letters on screen; embeddings and isolates (U+202B, U+2067) keep Latin text forwards.
--   4. A custom status is checked like a bio. It was the one free-text field on a profile with no slur check.

create or replace function public.six_nine_g(t text)
 returns text language plpgsql immutable set search_path to 'public' as $function$
declare
  s text := regexp_replace(public.fold_fancy(coalesce(t, '')),
    '(?<![[:alnum:]])([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|[0-9a-fA-F]{20,})(?![[:alnum:]])', ' ', 'g');
  n int := 0;
begin
  -- each pass reads the first digit of a run (ni9669er needs three); a long run is still mostly g's after 8
  while n < 8 and s ~ '[[:alpha:]][69]+[[:alpha:]]' loop
    s := regexp_replace(s, '(?<=[[:alpha:]])[69](?=[69]*[[:alpha:]])', 'g', 'g');
    n := n + 1;
  end loop;
  return s;
end $function$;

-- The checks that were has_slur (same word lists as the live body), with the wider masked check.
create or replace function public.has_slur_plain(t text)
 returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select
    (' ' || public.slur_text(t) || ' ') ~ (
      ' (s+a+n+d+)?(n+[iy]+g+g+(e+r+|a+|a+h+|a+z+|u+h+|e+r+z+|l+e+t+)s*|n+g+a+s*'
      || '|f+a+g+(g+[oei]+t+)?s*|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a+n+n+(y+|i+e+)s*'
      || '|r+e+t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i+n+k+s*|c+o+o+n+s*|d+y+k+e+s*|n+i+g+s*) '
    )
    -- the worst ones, even glued inside other words ("xniggerx")
    or replace(public.slur_text(t), ' ', '') ~ 'n+[iy]+g+g+(e+r+|a+)|n+e+g+g+(e+r+|r+e*|a+)|f+a+g+g+[oei]+t+'
    -- masked: n**ga, n@igg@, re*tard, r*tard, k*ike (symbols stripped, then whole-word stems; a vowel may be the
    -- one the symbol replaced). Only when a symbol was there.
    or (
      (' ' || regexp_replace(lower(unaccent(public.fold_fancy(t))), '[*#@$%&!?_.\-]+', '', 'g') || ' ')
        ~ (' (n[iy]*g+g*(a+|e+r+|a+h+|e+t+)?|f[a]*g+g*(o+t+|e+t+|i+t+)?'
           || '|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a*n+n+(y+|i+e+)s*'
           || '|r+e*t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i*n+k+s*|c+o+o+n+s*|d+y+k+e+s*) ')
      and lower(coalesce(t, '')) ~ '[*#@$%&!?_.\-]'
    );
$function$;

create or replace function public.has_slur(t text)
 returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select public.has_slur_plain(t)
    -- 6 / 9 inside a word read as g (the precheck only folds text that has something beyond plain ascii in it)
    or (
      (coalesce(t, '') ~ '[[:alpha:]][69]+[[:alpha:]]'
        or (coalesce(t, '') ~ '[^\x01-\x7f]' and public.fold_fancy(t) ~ '[[:alpha:]][69]+[[:alpha:]]'))
      and public.has_slur_plain(public.six_nine_g(t))
    )
    -- a right-to-left override (U+202E) makes a reversed word read forwards on screen
    or (
      strpos(coalesce(t, ''), chr(8238)) > 0
      and (public.has_slur_plain(reverse(t)) or public.has_slur_plain(public.six_nine_g(reverse(t))))
    );
$function$;

-- Same callers as has_slur (authenticated and service_role), nobody else.
revoke all on function public.six_nine_g(text) from public, anon;
revoke all on function public.has_slur_plain(text) from public, anon;
grant execute on function public.six_nine_g(text) to authenticated, service_role;
grant execute on function public.has_slur_plain(text) to authenticated, service_role;

create or replace trigger profiles_status_no_slurs before insert or update of custom_status on public.profiles
  for each row execute function public.no_slurs('custom_status');
