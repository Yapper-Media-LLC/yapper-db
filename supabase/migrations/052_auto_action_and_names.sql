-- 027's auto-action trigger never made it to production: reports from 8+ people in an hour
-- (or a slur reported by 2+) didn't auto-ban. Put it back.
drop trigger if exists reports_auto_action on public.reports;
create trigger reports_auto_action after insert on public.reports for each row execute function public.auto_action_new_report();

-- Names: catch the vowel swaps (v or * instead of a/u) people use to get around the list.
create or replace function public.bad_name(t text) returns boolean language sql immutable set search_path = public, extensions as $$
  select public.has_slur(t)
    or replace(public.slur_text(t), ' ', '') ~ ('(porn|hentai|nsfw|rape|rapist|pedo|paedo|cheesepizza|childp|sexoffen|hitler|nazi|kkk|lynch|onlyfans|nudes|sexting|pussy|vagina|penis|cocks?uck|blowjob|cumshot|cumslut|whore|slut|jailbait|loli|shota|kys|killyourself|suicide|selfharm)')
    or replace(public.slur_text(t), ' ', '') ~ ('(r[v*]p(e|ist)|[ck][uv*]nn(y|ie))')
    or (' ' || public.slur_text(t) || ' ') ~ ' (sex|sexy|cum|dick|cock|fuck|fucking|fucked|shit|bitch|anal|boobs|tits|horny|nude|nigga|cp|csam) ';
$$;
