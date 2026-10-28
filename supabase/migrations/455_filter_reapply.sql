-- 455: the word filter from 430 is applied again. 430 is recorded as applied (Oct 23) and has_self_harm_incitement exists live,
-- but slur_text, has_slur_plain and the create_poll option check were back at their pre-430 bodies on Oct 24 (something
-- re-created them from an older text): live has_slur('niigerr') and slur_text('niᵹᵹa') showed it. Same content as 430,
-- re-runnable, functions only, no data touched. Safe any time.

create or replace function public.slur_text(t text)
returns text language sql immutable set search_path to 'public', 'extensions' as $function$
  select regexp_replace(
    regexp_replace(
      translate(
        lower(unaccent(regexp_replace(public.fold_fancy(t), '[​-‏⁠﻿­]', '', 'g'))),
        'аеорсухіјѕԁԛԝһɡɪıɑοαενκρτυιɴɢʀꜰᴀᴇᴏᴜᴛᴋᴘꜱ0134578@$!|ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚпгмтнвкишηβγσςχψωϲᵹɠǥꞡᶃꝿɨɩӏ',
        'aeopcyxijsdqwhgiiaoaevkptuingrfaeoutkpsoieastbasiiabcdefghijklmnopqrstuvwxyznrmthbkuwnbyosxywcggggggiii'),
      '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g');
$function$;

create or replace function public.has_slur_plain(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select
    (' ' || public.slur_text(t) || ' ') ~ (
      ' (s+a+n+d+)?(n+[iy]+g+g+(e+r+|a+|a+h+|a+z+|u+h+|e+r+z+|l+e+t+)s*|n+g+a+s*'
      || '|n+[iy][iy]+g+e+r+s*|n+[iy]+g+e+r+r+s*|n+[iy]+g+r+s*'
      || '|f+a+g+(g+[oei]+t+)?s*|f+g+g*o+t+s*|f+g+g+[ei]+t+s*|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a+n+n+(y+|i+e+)s*'
      || '|r+e+t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i+n+k+s*|c+o+o+n+s*|d+y+k+e+s*|n+i+g+s*) '
    )
    or replace(public.slur_text(t), ' ', '') ~ 'n+[iy]+g+g+(e+r+|a+)|f+a+g+g+[oei]+t+'
    or public.slur_text(t) ~ 'n+e+g+g+(e+r+|r+e*|a+)'
    or public.slur_text(t) ~ '\mn+ ?e+ ?g+ ?g+ ?(e+ ?r+|r+ ?e*|a+)'
    or (
      (' ' || regexp_replace(lower(unaccent(public.fold_fancy(t))), '[*#@$%&!?_.\-§¤~^•·¡¿]+', '', 'g') || ' ')
        ~ (' (n[iy]*g+g*(a+|e+r+|a+h+|e+t+)?|f[a]*g+g*(o+t+|e+t+|i+t+)?'
           || '|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a*n+n+(y+|i+e+)s*'
           || '|r+e*t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i*n+k+s*|c+o+o+n+s*|d+y+k+e+s*) ')
      and lower(coalesce(t, '')) ~ '[*#@$%&!?_.\-§¤~^•·¡¿]'
    );
$function$;

-- "kill" read loosely (any run of i/l after the k: kiii, kiII, klll, kil), more ways to say "yourself", and a second
-- reading with masking symbols taken out (k*ll yourself). Whole phrase only, so "skill" or "kill the boss" stay fine.
create or replace function public.has_self_harm_incitement(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  with p(rx) as (select
    ' (kys|k+y+s+|k+[il][il]+ ?(your|yur|ur|yo|ya|u) ?(self|selves|slf)|go ?(and )?die|hang ?(your|ur|yo) ?self'
    || '|neck ?(your|ur|yo) ?self|unalive ?(your|ur|yo) ?self|end ?(your|ur|yo) ?self|drink ?bleach'
    || '|slit ?(your|ur) ?wrists?|you should die|nobody would miss you) ')
  select (' ' || public.slur_text(t) || ' ') ~ p.rx
      -- Only when a masking symbol sits between letters (k*ll), so ordinary punctuation doesn't cost a second read.
      or (coalesce(t, '') ~ '[[:alpha:]][*#%&?_.\-§¤~^•·]+[[:alpha:]]'
          and (' ' || public.slur_text(regexp_replace(t, '[*#%&?_.\-§¤~^•·]+', '', 'g')) || ' ') ~ p.rx)
  from p;
$function$;

-- Poll options: the same slur and self-harm checks as a message. Patched into the live create_poll.
do $$
declare
  f text;
  old_part text := E'    o := o || jsonb_build_object(''id'', i::text, ''text'', trim(opts[i]));';
  new_part text := E'    -- 430: options are checked like a message (the question already is, as the poll''s message).\n'
    || E'    if public.has_slur(opts[i]) then raise exception ''That contains a slur, so it wasn''''t sent. Keep it respectful.'' using errcode = ''check_violation''; end if;\n'
    || E'    if public.has_self_harm_incitement(opts[i]) then raise exception ''Telling someone to hurt themselves isn''''t allowed on Yapper.'' using errcode = ''check_violation''; end if;\n'
    || old_part;
begin
  for f in select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'create_poll' loop
    if position('-- 430: options are checked' in f) > 0 then continue; end if; -- already patched
    if position(old_part in f) = 0 then raise exception '430: create_poll changed, patch its option check by hand'; end if;
    execute replace(f, old_part, new_part);
  end loop;
end $$;
