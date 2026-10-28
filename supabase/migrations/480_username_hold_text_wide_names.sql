-- 480: username hold message + giant characters in display names. NOT applied (database freeze Oct 25).
--
-- 1. username_holds_guard (246, patched by 331) said "it was just let go and is held until <date>". A name a moderator
--    reset is held 30 days (277), so someone who picked "yz" got "held until November 19" and thought holds were broken
--    ("the hold shouldn't be more than 7 days"). Same check, plainer words that fit both kinds of hold.
--    Patched by exact line from the live text (pg_get_functiondef, read Oct 25), like 331 did, so nothing else in the
--    function changes. Both raise lines (INSERT and UPDATE branch) on purpose.
-- 2. A display name could be one ﷽ (U+FDFD) or cuneiform signs that draw several times wider than a letter, which
--    turned names into huge blocks in chat and member lists. A small BEFORE trigger (named profiles_00_... so it fires before
--    the name guards: otherwise "Dis﷽cord" passed the brand / bad-name checks and came out as "Discord") drops them from
--    display_name (an empty result means no display name). Usernames are ASCII only already (profiles_username_check).
--    The app strips the same set before saving (lib/actions.ts WIDE_GLYPHS), so people don't hit this on purpose.
--
-- 3. Find people (search_people, 141) only looked past your friends from 3 letters on, but usernames can be 2 letters,
--    so nobody could find "yz" ("you can't search for users with 2-character usernames"). A 2-letter search now also
--    finds that exact username (same server + online rules as before). It stays an index range lookup: the range
--    bounds are still there, only the length test gets "or an exact match". Patched by exact line (live text Oct 25
--    matches 141 for this line).
--
-- Re-runnable. Only touches functions/triggers (DDL): apply in quiet hours, one go.

set lock_timeout = '2s';

-- ---------- 1: hold message ----------
do $$
declare d text; n text; n_hits int;
  anchor text := $a$raise exception 'That username is taken for now: it was just let go and is held until % UTC.',$a$;
  repl text := $a$raise exception 'That username is on hold until % UTC, so nobody can take it yet.',$a$;
begin
  d := pg_get_functiondef('public.username_holds_guard()'::regprocedure);
  if position('is on hold until' in d) > 0 then return; end if; -- already patched
  n_hits := (length(d) - length(replace(d, anchor, ''))) / length(anchor);
  if n_hits <> 2 then raise exception 'username_holds_guard changed: expected the line 2 times, found %. Read its live text again', n_hits; end if;
  n := replace(d, anchor, repl);
  execute n;
end $$;

-- ---------- 3: 2-letter usernames in Find people ----------
do $$
declare d text; n text; n_hits int;
  anchor text := E'where char_length(needle) >= 3\n        and (lower(p.username) collate "C") >= needle';
  repl text := E'where (char_length(needle) >= 3 or lower(p.username) = needle)\n        and (lower(p.username) collate "C") >= needle';
begin
  d := pg_get_functiondef('public.search_people(text)'::regprocedure);
  if position('or lower(p.username) = needle)' in d) > 0 then return; end if; -- already patched
  n_hits := (length(d) - length(replace(d, anchor, ''))) / length(anchor);
  if n_hits <> 1 then raise exception 'search_people changed: expected the line once, found %. Read its live text again', n_hits; end if;
  n := replace(d, anchor, repl);
  execute n;
end $$;

-- ---------- 2: giant characters in display names ----------
create or replace function public.profiles_strip_wide_glyphs()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.display_name is not null then
    -- ﷺ ﷻ ﷼ ﷽, ⸺ ⸻, cuneiform (U+12000-U+1254F)
    new.display_name := nullif(btrim(regexp_replace(new.display_name, '[ﷺ-﷽⸺⸻\U00012000-\U0001254F]', '', 'g')), '');
  end if;
  return new;
end $$;
revoke execute on function public.profiles_strip_wide_glyphs() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'profiles_00_wide_glyphs' and tgrelid = 'public.profiles'::regclass) then
    create trigger profiles_00_wide_glyphs before insert or update of display_name on public.profiles
      for each row execute function public.profiles_strip_wide_glyphs();
  end if;
end $$;
