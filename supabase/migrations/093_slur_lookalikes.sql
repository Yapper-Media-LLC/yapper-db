-- Slur filter: more Cyrillic and Greek look-alikes folded to Latin before matching (applied live Oct 15).
-- "пiggers" (Cyrillic п) got through; п г м т н в к и ш and η β γ σ ς χ ψ ω ϲ are mapped now.
create or replace function public.slur_text(t text)
 returns text language sql immutable set search_path to 'public', 'extensions' as $function$
  select regexp_replace(
    regexp_replace(
      translate(
        lower(unaccent(regexp_replace(coalesce(t, ''), '[​-‏⁠﻿­]', '', 'g'))),
        'аеорсухіјѕԁԛԝһɡɪıɑοαενκρτυιɴɢʀꜰᴀᴇᴏᴜᴛᴋᴘꜱ0134578@$!|ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚпгмтнвкишηβγσςχψωϲ',
        'aeopcyxijsdqwhgiiaoaevkptuingrfaeoutkpsoieastbasiiabcdefghijklmnopqrstuvwxyznrmthbkuwnbyosxywc'),
      '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g');
$function$;
