-- 390: bug fixes, Oct 22. Functions only, re-runnable.
--  * Word filter: all-caps slurs with a lowercase l standing in for I ("NlGGA") and "Nlgga" at the start of a word, and the
--    vowel-dropped f-slur as a whole word ("fgot", "fggot"). has_slur keeps the 273 body plus one check; has_slur_plain
--    keeps the 325 body with one more whole-word form. slur_text is untouched (other checks use it).
--  * Creator verification: channel names with letters like Ξ or Ø ("ZΞRØ") were refused after the name already matched.
--    Only invisible and control characters are refused now (patched into the live apply_verification text).

create or replace function public.has_slur_plain(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select
    (' ' || public.slur_text(t) || ' ') ~ (
      ' (s+a+n+d+)?(n+[iy]+g+g+(e+r+|a+|a+h+|a+z+|u+h+|e+r+z+|l+e+t+)s*|n+g+a+s*'
      || '|f+a+g+(g+[oei]+t+)?s*|f+g+g*o+t+s*|f+g+g+[ei]+t+s*|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a+n+n+(y+|i+e+)s*'
      || '|r+e+t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i+n+k+s*|c+o+o+n+s*|d+y+k+e+s*|n+i+g+s*) '
    )
    or replace(public.slur_text(t), ' ', '') ~ 'n+[iy]+g+g+(e+r+|a+)|f+a+g+g+[oei]+t+'
    or public.slur_text(t) ~ 'n+e+g+g+(e+r+|r+e*|a+)'
    or public.slur_text(t) ~ '\mn+ ?e+ ?g+ ?g+ ?(e+ ?r+|r+ ?e*|a+)'
    or (
      (' ' || regexp_replace(lower(unaccent(public.fold_fancy(t))), '[*#@$%&!?_.\-]+', '', 'g') || ' ')
        ~ (' (n[iy]*g+g*(a+|e+r+|a+h+|e+t+)?|f[a]*g+g*(o+t+|e+t+|i+t+)?'
           || '|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a*n+n+(y+|i+e+)s*'
           || '|r+e*t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i*n+k+s*|c+o+o+n+s*|d+y+k+e+s*) ')
      and lower(coalesce(t, '')) ~ '[*#@$%&!?_.\-]'
    );
$function$;

-- A lowercase l between capitals (NlGGA), or right after a word-initial N before a g (Nlgga), is read as I.
create or replace function public.has_slur(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select public.has_slur_plain(t)
    or (
      (coalesce(t, '') ~ '[[:alpha:]][69]+[[:alpha:]]'
        or (coalesce(t, '') ~ '[^\x01-\x7f]' and public.fold_fancy(t) ~ '[[:alpha:]][69]+[[:alpha:]]'))
      and public.has_slur_plain(public.six_nine_g(t))
    )
    or (
      strpos(coalesce(t, ''), chr(8238)) > 0
      and (public.has_slur_plain(reverse(t)) or public.has_slur_plain(public.six_nine_g(reverse(t))))
    )
    or (
      -- fold_fancy only when needed (plain ASCII text without the pattern skips it), like the 6/9 check above.
      (coalesce(t, '') ~ '[[:upper:]]l[[:upper:]]|\m[Nn]l[gG]'
        or (coalesce(t, '') ~ '[^\x01-\x7f]' and public.fold_fancy(t) ~ '[[:upper:]]l[[:upper:]]|\m[Nn]l[gG]'))
      and public.has_slur_plain(regexp_replace(regexp_replace(public.fold_fancy(t),
            '([[:upper:]])l(?=[[:upper:]])', '\1I', 'g'), '\m([Nn])l(?=[gG])', '\1I', 'g'))
    );
$function$;

do $$
declare f text;
  old_line constant text := 'if handle !~ ''^[A-Za-z0-9._ -]{1,60}$'' then';
  -- Invisible and control characters (written as escapes so editors can't strip them), and the middle dot that
  -- separates platform and handle in verified_as ("YouTube · name").
  new_line constant text := 'if char_length(handle) > 60 or handle !~ ''[[:alnum:]]'' '
    || 'or handle ~ ''[[:cntrl:]\u00ad\u00b7\u034f\u061c\u115f\u1160\u180b-\u180f\u200b-\u200f\u202a-\u202e\u2060-\u206f\u2800\u3164\ufe00-\ufe0f\ufeff\uffa0\U000e0000-\U000e007f]'' then';
begin
  if to_regprocedure('public.apply_verification(text,text,text,text,text)') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.apply_verification(text,text,text,text,text)'::regprocedure);
  if position(new_line in f) > 0 then return; end if; -- already patched
  if position(old_line in f) = 0 then raise exception '390: apply_verification changed, patch the handle check by hand'; end if;
  execute replace(f, old_line, new_line);
end $$;
