-- 156: sexual spam (17 Oct: "pocketp7ssy" posted 109 sexual sales ads in one server).
--  * bad_name: digits/symbols in place of a vowel ("p7ssy" became "ptssy" after slur_text) and "dildo".
--  * Messages: has_sexual_spam(t) blocks text with two explicit sexual terms, or one together with
--    selling words (order, buy, sell, free, cheap, dm me, prices). One rude word in normal chat passes.
--    Checked in message_automod on insert and edit (bots skip it, like the rest of automod).
-- Tested 17 Oct: 0 hits in 6000 recent messages; catches the ads. "nsfw" alone was dropped (server rules mention it).
-- Re-runnable.

create or replace function public.has_sexual_spam(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $$
  with s as (select ' ' || public.slur_text(coalesce(t, '')) || ' ' as x),
  hits as (
    select count(distinct m[1]) n from s, regexp_matches(replace(s.x, ' ', ''),
      '(p[uv*t]ss(y|ie)|dildo|vibrator|porn|onlyfans|nudes|hentai|blowjob|handjob|cumshot|cumslut|sexting|fleshlight|buttplug|strapon|creampie|deepthroat|camgirl|sexcam|sextape|lube|durex)', 'g') m
  )
  select coalesce((select n from hits), 0) >= 2
      or (coalesce((select n from hits), 0) >= 1
          and (select x from s) ~ ' (order|orders|buy|buying|sell|selling|sale|free|cheap|discount|price|prices|shop|store|dm|dms|link|links|telegram|snap|snapchat|cashapp|paypal|sponsored|promo|deal|deals) ');
$$;
revoke all on function public.has_sexual_spam(text) from public, anon;

create or replace function public.bad_name(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $$
  select public.has_slur(t)
    or replace(public.slur_text(t), ' ', '') ~ ('(porn|hentai|nsfw|rape|rapist|pedo|paedo|cheesepizza|childp|sexoffen|hitler|nazi|kkk|lynch|onlyfans|nudes|sexting|pussy|vagina|penis|cocks?uck|blowjob|cumshot|cumslut|whore|slut|jailbait|loli|shota|kys|killyourself|suicide|selfharm|dildo)')
    -- vowel swaps people use to dodge the list above (v, *, or a digit that slur_text turned into a letter)
    or replace(public.slur_text(t), ' ', '') ~ ('(r[v*]p(e|ist)|[ck][uv*]nn(y|ie)|p[uv*t]?ss(y|ie)|d[i1l]ld[o0]|p[o0]rn)')
    or (' ' || public.slur_text(t) || ' ') ~ ' (sex|sexy|cum|dick|cock|fuck|fucking|fucked|shit|bitch|anal|boobs|tits|horny|nude|nigga|cp|csam) ';
$$;

do $$ declare d text; begin
  d := pg_get_functiondef('public.message_automod()'::regprocedure);
  if position('has_sexual_spam' in d) = 0 then
    d := replace(d, E'  if public.has_self_harm_incitement(new.content) then\n',
      E'  if public.has_sexual_spam(new.content) then\n'
      || E'    raise exception ''Sexual content and selling it aren''''t allowed on Yapper.'' using errcode = ''check_violation'';\n'
      || E'  end if;\n'
      || E'  if public.has_self_harm_incitement(new.content) then\n');
    if position('has_sexual_spam' in d) = 0 then raise exception 'message_automod patch did not apply'; end if;
    execute d;
  end if;
end $$;
