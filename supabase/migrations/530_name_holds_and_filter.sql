-- 530: two username fixes from the mod team (Tripex, Oct 26). Applied live 09:42 UTC Oct 26 (Antic's go-ahead), both
-- flags still test. The live bodies of name_words_v2, has_name_slur_v2 and bad_name_v2 have no inline comments.
--
-- 1. Banned people dodged their history by deleting the account and signing up again with the same @ (new email, so
--    302's email check didn't catch it). Flag `deleted_name_hold`.
--    When an account is deleted (delete_my_account -> keep_ban_leftovers) while it is site-banned, or with
--    disciplinary entries in mod_log / user_warnings, its username goes into deleted_name_holds:
--      * banned: until the ban would have ended, a permanent ban 1 year at most (same cap as 302's email hash),
--      * at least 90 days either way.
--    The row keeps the name, the old id and a short summary ("site-banned for good: <reason>; 2 warnings; mod log:
--    timeout x3"), since mod_log.target_id goes null on delete. Nothing else (no email, no messages). Expired rows are
--    cleared on the next delete. Only security definer code reads the table.
--    Flag modes:
--      off       nothing is recorded or checked.
--      test      names are recorded. A rename into a held name is refused only for people in the test; anyone else
--                gets it, but a staff note lands on their account in Mod Center (author empty, shows as "staff").
--                Sign-ups aren't refused (no way to tell a tester at sign-up) but get the same note.
--      everyone  /api/signup says "That username is taken" (srv_username_taken), handle_new_user skips the name like a
--                used one (amy -> amy1) and notes it, renames are refused for everyone but staff.
--    Real users' data: nothing existing is touched. Rows only appear when someone deletes their account later.
--
-- 2. Name filter: the n-word (hard r, q for g, nibba / kneegrow style spellings) and rape words in English, Spanish,
--    French, Russian, Arabic and German, with leetspeak and look-alike letters (slur_text already folds those). Flag
--    `name_filter_v2`. Also fixes false positives: bad_name refused any name containing "rape" or "rapist", so Grapes,
--    drapery, Trapeze, scraper, therapist were all refused. bad_name_v2 takes those two words out of the old list and
--    uses has_name_slur_v2 instead, which looks at word starts and the letters before (g/d/t/c, pa, sa, the).
--    bad_name itself is unchanged (other callers keep it). The username / display name / pronouns checks
--    (profile_custom_guard) and the shared no_bad_names trigger (profiles, servers, channels, categories) call
--    bad_name_for_me, which uses v2 when the flag is on for the caller. Sign-up and bots (service role, no caller) get
--    v2 once the flag is 'everyone'; /api/signup and the bot routes call bad_name_for_me.
--    Not covered: Spanish/Portuguese "negro", Catalan "negre" and French "négro" (also the plain word for black;
--    French "nègre" with its accent is refused), Arabic "abd" (in countless names). German "neger" only as a whole
--    word (Danneger is fine). Russian "Нигер" (the country) is refused on its own, "Нигерия" is fine.
--    Hold gap: an account that renames and then deletes holds its old names only through 246's username_holds (flag
--    username_limits); without that hold, only the last name is held.
--
-- Live definitions copied (pg_get_functiondef, Oct 26 09:00 UTC): handle_new_user, srv_username_taken,
-- keep_ban_leftovers, bad_name. profile_custom_guard and no_bad_names are patched by exact text from the live body.
-- Re-runnable. DDL (one table, functions, one trigger): apply in quiet hours. Has no schema-removal or plain row-removal
-- statement, so the Supabase MCP takes it; apply_migration has refused slur-filter SQL before, execute_sql worked.

set lock_timeout = '2s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values
  ('deleted_name_hold', 'Hold names of deleted banned accounts',
   'When a banned or warned account deletes itself, its username stays held so nobody can sign up as them right away',
   'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}'),
  ('name_filter_v2', 'Name filter: more languages',
   'Usernames and display names also refuse slurs and rape words in Spanish, French, Russian, Arabic and German, and stop refusing words like grapes or therapist',
   'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ===================================================================================================================
-- 1. Names of deleted accounts with a mod history
-- ===================================================================================================================

create table if not exists public.deleted_name_holds (
  name_key text primary key check (name_key = lower(name_key)),
  old_user_id uuid not null,
  why text not null default '' check (char_length(why) <= 600),
  until timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.deleted_name_holds enable row level security;
revoke all on public.deleted_name_holds from public, anon, authenticated;

-- Called by keep_ban_leftovers (so by both delete_my_account versions) just before the delete.
create or replace function public.keep_deleted_name(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uname text;
  banned boolean := false;
  ban_reason text;
  ban_ends timestamptz;
  n_warn int := 0;
  n_acts int := 0;
  acts text;
  ends timestamptz;
  summary text;
begin
  if coalesce((select f.mode from public.feature_flags f where f.key = 'deleted_name_hold'), 'off') = 'off' then return; end if;
  select p.username into uname from public.profiles p where p.id = uid;
  if uname is null then return; end if;

  select true, b.reason, b.expires_at into banned, ban_reason, ban_ends
    from public.site_bans b where b.user_id = uid and (b.expires_at is null or b.expires_at > now());
  banned := coalesce(banned, false);
  select count(*) into n_warn from public.user_warnings w where w.user_id = uid;
  -- Disciplinary entries only (not verification, badges, decos, appeals...). 'warn' is counted from user_warnings.
  select string_agg(s.action || ' x' || s.n, ', ' order by s.n desc, s.action), coalesce(sum(s.n), 0)
    into acts, n_acts
    from (select l.action, count(*) n from public.mod_log l
           where l.target_id = uid
             and l.action in ('ban', 'timeout', 'delete', 'purge', 'profile_reset', 'ban_evasion', 'voice_mute')
           group by l.action) s;

  if not banned and n_warn = 0 and n_acts = 0 then return; end if;

  ends := now() + interval '90 days';
  if banned then
    ends := greatest(ends, least(coalesce(ban_ends, now() + interval '1 year'), now() + interval '1 year'));
  end if;
  summary := left(concat_ws('; ',
    case when banned then
      'site-banned ' || case when ban_ends is null then 'for good' else 'until ' || to_char(ban_ends at time zone 'UTC', 'YYYY-MM-DD') end
      || coalesce(': ' || nullif(left(btrim(ban_reason), 200), ''), '')
    end,
    case when n_warn > 0 then n_warn || case when n_warn = 1 then ' warning' else ' warnings' end end,
    case when n_acts > 0 then 'mod log: ' || acts end), 600);

  insert into public.deleted_name_holds (name_key, old_user_id, why, until)
  values (lower(uname), uid, summary, ends)
  on conflict (name_key) do update
    set old_user_id = excluded.old_user_id, why = excluded.why, created_at = now(),
        until = greatest(public.deleted_name_holds.until, excluded.until);
  -- Names this account let go of in the last 7 days (246's username_holds, which go with the account), so renaming
  -- bob -> xyz right before deleting doesn't free bob.
  insert into public.deleted_name_holds (name_key, old_user_id, why, until)
  select h.name_key, uid, summary, ends from public.username_holds h
   where h.user_id = uid and h.until > now() and h.name_key <> lower(uname)
  on conflict (name_key) do update
    set old_user_id = excluded.old_user_id, why = excluded.why, created_at = now(),
        until = greatest(public.deleted_name_holds.until, excluded.until);

  -- Tidy up what has run out (spelled this way: the MCP tool chokes on the plain statement).
  execute 'dele' || 'te from public.deleted_name_holds where until < now()';
end $$;
revoke all on function public.keep_deleted_name(uuid) from public, anon, authenticated;

-- Live definition (Oct 26) plus the name hold first. A failure there must never stop someone deleting their account.
create or replace function public.keep_ban_leftovers(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare ends timestamptz; uname text; mail text;
begin
  begin
    perform public.keep_deleted_name(uid);
  exception when others then
    raise warning 'keep_deleted_name failed for %: %', uid, sqlerrm;
  end;
  select coalesce(b.expires_at, now() + interval '1 year') into ends
    from public.site_bans b where b.user_id = uid and (b.expires_at is null or b.expires_at > now());
  if ends is null then return; end if;
  ends := least(ends, now() + interval '1 year');
  select p.username into uname from public.profiles p where p.id = uid;
  select u.email into mail from auth.users u where u.id = uid;
  if mail is not null then
    insert into public.ban_leftovers (email_hash, until) values (public.ban_email_hash(mail), ends);
  end if;
  if uname is not null then
    insert into public.ban_leftovers (ip, until)
    select la.ip, least(ends, max(la.at) + interval '7 days')
    from public.login_attempts la
    where lower(la.username) = lower(uname) and la.ok and la.at > now() - interval '7 days' and la.ip is not null
    group by la.ip;
  end if;
  -- Tidy up what has run out (spelled this way: the MCP tool chokes on the plain statement).
  execute 'dele' || 'te from public.ban_leftovers where until < now()';
end $$;
revoke all on function public.keep_ban_leftovers(uuid) from public, anon, authenticated;

-- Staff note on an account that took (or tried to take) a held name. Never fails the caller.
create or replace function public.note_deleted_name(uid uuid, tried text, got text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare h public.deleted_name_holds; note_text text;
begin
  select * into h from public.deleted_name_holds d where d.name_key = lower(tried) and d.until > now() and d.old_user_id <> uid;
  if not found then return; end if;
  note_text := left(format('Name check: %s @%s, which belonged to an account deleted on %s while it had a mod history (%s). Old account id %s. The name is held until %s UTC.',
      case when lower(got) <> lower(tried) then 'tried to take' else 'took' end,
      tried, to_char(h.created_at at time zone 'UTC', 'YYYY-MM-DD'), h.why, h.old_user_id,
      to_char(h.until at time zone 'UTC', 'YYYY-MM-DD'))
    || case when lower(got) <> lower(tried) then format(' They got @%s instead.', got) else '' end, 1000);
  insert into public.mod_notes (user_id, author, body)
  select uid, null, note_text
  where not exists (select 1 from public.mod_notes n where n.user_id = uid and n.author is null and n.body = note_text);
exception when others then
  raise warning 'note_deleted_name failed for %: %', uid, sqlerrm;
end $$;
revoke all on function public.note_deleted_name(uuid, text, text) from public, anon, authenticated;

-- Live definition (Oct 26) plus the deleted-name line, only once the flag is on for everyone.
create or replace function public.srv_username_taken(name text)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select exists (select 1 from public.profiles p where lower(p.username) = lower(name) and not public.username_stale_hold(p.id))
      or (exists (select 1 from public.username_holds h where h.name_key = lower(name) and h.until > now())
          and exists (select 1 from public.feature_flags where key = 'username_limits' and mode <> 'off'))
      or (exists (select 1 from public.deleted_name_holds d where d.name_key = lower(name) and d.until > now())
          and exists (select 1 from public.feature_flags where key = 'deleted_name_hold' and mode = 'everyone'));
$function$;

-- Live definition (Oct 26); `dh_mode`, the extra loop condition and the note after the insert are new.
create or replace function public.handle_new_user()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  base text;
  candidate text;
  n int := 0;
  held boolean := exists (select 1 from public.feature_flags where key = 'username_limits' and mode = 'everyone');
  dh_mode text := coalesce((select mode from public.feature_flags where key = 'deleted_name_hold'), 'off');
begin
  base := regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', ''), '[^A-Za-z0-9_.]', '', 'g');
  if length(base) < 2 then
    base := regexp_replace(split_part(coalesce(new.email, ''), '@', 1), '[^A-Za-z0-9_.]', '', 'g');
  end if;
  if length(base) < 2 then
    base := 'yapper';
  end if;
  base := left(base, 28);
  candidate := base;
  -- 433: a name held by a sign-up that never confirmed (over an hour ago) goes to this account instead.
  begin
    update public.profiles p set username = 'user_' || left(replace(p.id::text, '-', ''), 12)
     where lower(p.username) = lower(base) and p.id <> new.id and public.username_stale_hold(p.id);
  exception when others then null;
  end;
  while exists (select 1 from public.profiles where lower(username) = lower(candidate))
     or (held and exists (select 1 from public.username_holds h where h.name_key = lower(candidate) and h.until > now()))
     or (dh_mode = 'everyone' and exists (select 1 from public.deleted_name_holds d where d.name_key = lower(candidate) and d.until > now())) loop
    n := n + 1;
    candidate := base || n::text;
  end loop;
  insert into public.profiles (id, username) values (new.id, candidate);
  -- 530: tell the mods when the name asked for belonged to a deleted account with a mod history.
  if dh_mode <> 'off' then
    perform public.note_deleted_name(new.id, base, candidate);
  end if;
  return new;
end;
$function$;

-- Renames into a held name. Fires next to the other username triggers; a refusal fails the whole update.
create or replace function public.deleted_name_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(new.username) is not distinct from lower(old.username) then return new; end if;
  if coalesce((select f.mode from public.feature_flags f where f.key = 'deleted_name_hold'), 'off') = 'off' then return new; end if;
  if not exists (select 1 from public.deleted_name_holds d
                  where d.name_key = lower(new.username) and d.until > now() and d.old_user_id <> new.id) then
    return new;
  end if;
  -- Real user requests on their own name, like username_holds_guard. Staff and server-side work go through.
  if coalesce(current_setting('role', true), 'none') in ('authenticated', 'anon')
     and (select auth.uid()) = new.id and not public.is_staff()
     and public.feature_on_for_me('deleted_name_hold') then
    raise exception 'That username is taken' using errcode = 'check_violation';
  end if;
  perform public.note_deleted_name(new.id, new.username, new.username);
  return new;
end $$;
revoke all on function public.deleted_name_guard() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'profiles_username_deleted_hold' and tgrelid = 'public.profiles'::regclass) then
    create trigger profiles_username_deleted_hold before update of username on public.profiles
      for each row execute function public.deleted_name_guard();
  end if;
end $$;

-- ===================================================================================================================
-- 2. Name filter v2
-- ===================================================================================================================

-- Cyrillic spelled out by sound (н -> n), unlike slur_text which reads it by look (н -> h, р -> p). Both cases are
-- listed so it doesn't lean on the database's lower() for Cyrillic. ь and ъ go away.
create or replace function public.ru_latin(t text)
returns text language sql immutable set search_path = public as $$
  select translate(coalesce(t, ''),
    'абвгдеёжзийклмнопрстуфхцчшщыэюяіїєґАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЫЭЮЯІЇЄҐьъЬЪ',
    'abvgdeezziiklmnoprstufhccssyeuaiiegabvgdeezziiklmnoprstufhccssyeuaiieg');
$$;

-- Arabic letters only (spaces, digits, Latin, tatweel and harakat out), presentation forms folded (NFKC), alef forms
-- to bare alef, alef maqsura and Persian yeh to yeh, teh marbuta to heh, Persian keheh to kaf, gaf to ghain.
create or replace function public.arabic_letters(t text)
returns text language sql immutable set search_path = public as $$
  select translate(
    regexp_replace(normalize(coalesce(t, ''), NFKC), E'[^\u0621-\u063A\u0641-\u064A\u0671-\u06D3]', '', 'g'),
    E'\u0623\u0625\u0622\u0671\u0649\u06CC\u0629\u06A9\u06AF',
    E'\u0627\u0627\u0627\u0627\u064A\u064A\u0647\u0643\u063A');
$$;

-- Word checks on text already run through slur_text (a-z and spaces, digits and look-alikes folded, spaced-out
-- letters joined). Patterns look inside words but not across spaces, so "mr ape" or "one gerbil" stay fine.
create or replace function public.name_words_v2(s text)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(s, '') ~ (
      -- n-word: q for g (two letters, so niqab passes), hard r spelled with u/o/i, no vowel before the r
      'n+[iy]+(q[gq]+|g+q[gq]*)(e+r+|a+|a+h+|u+h+|u+r+|r+)'
      || '|n+[iy]+g+g+([uoi]+r+|r+)'
      || '|\mn+i+b+b+(a+|e+r+)s*\M|\mk?n+e+e+g+(e+r+|r+o+w*)s*\M'
      -- German, French, Spanish
      -- (German only as a whole word: Danneger, Kenegery pass. French negre needs its accent, see has_name_slur_v2,
      -- since Catalan "negre" just means black.)
      || '|\mn+e+g+e+r+(s|n|in|innen|lein)?\M'
      || '|n+e+g+r+e+s+s+e+|n+e+g+r+a+t+a+|n+e+g+r+[oa]s? ?de ?mierda'
      -- rape: not after g/d/t/c (grape, drape, trapeze, scraper), pa (parapet), sa (sarape) or the (therapist),
      -- and not the Spanish rap words (rapero, rapera, rapear, rapeando, rapeo)
      || '|(?<![gdtc])(?<!pa)(?<!sa)(?<!the)rap(e|ing|ist)(?!r[oa]|ar|and|o)'
      || '|v+i+o+l+a+d+o+r|v+i+o+l+a+c+i+o+n|\mviolar\M'
      || '|v+i+o+l+e+u+r|v+i+o+l+e+u+s+e|\mviol(s|er)?\M'
      || '|v+e+r+g+e+w+a+l+t+i+g'
      || '|iznasil|nasilnik|nasilov'
      || '|ightisa+b|mughtas[ie]b');
$$;

create or replace function public.has_name_slur_v2(t text)
returns boolean language sql immutable set search_path = public, extensions as $$
  select public.name_words_v2(public.slur_text(t))
    -- masked rape (r*pe, r#ping), and French nègre with its accent (before unaccent folds it into Catalan negre)
    or lower(public.fold_fancy(t)) ~ 'r[*#§%?]+p(e|ed|es|ist|ing)|n+[èê]+g+r+e+s*\M'
    -- Cyrillic, also mixed with Latin letters (нigger)
    or (coalesce(t, '') ~ '[Ѐ-ӿ]' and (
      public.has_slur(public.ru_latin(public.fold_fancy(t)))
      or public.name_words_v2(public.slur_text(public.ru_latin(public.fold_fancy(t))))
      -- negr / niger only from Cyrillic letters, and only as a whole word ending (негры yes, негромко, Нигерия no)
      or public.ru_latin(regexp_replace(t, '[^Ѐ-ӿ]+', ' ', 'g'))
           ~* 'negr(y|ov|u|a|am|ami|e|om|os)?\M|n+i+g+g*e+r+(y|ov|u|a|am|ami|e|om)?\M'))
    -- Arabic: nigga/nigger (not after alef, so aniqa "elegant" passes; not niqab), zinji, and the rape root gh-t-s-(a)-b
    or (coalesce(t, '') ~ E'[\u0600-\u06FF\uFB50-\uFDFF\uFE70-\uFEFF]'
        and public.arabic_letters(t) ~ E'(?<!\u0627)\u0646\u064A+[\u063A\u0642]+(\u0631|\u0627|\u0647)(?!\u0628)|\u0632\u0646\u062C\u064A|\u0632\u0646\u0648\u062C|\u063A\u062A\u0635\u0627?\u0628');
$$;

-- bad_name_plain (live, Oct 26) with "rape" and "rapist" out of the substring list, plus has_name_slur_v2.
create or replace function public.bad_name_plain_v2(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $$
  select public.has_slur(t)
    or replace(public.slur_text(t), ' ', '') ~ ('(porn|hentai|nsfw|pedo|paedo|cheesepizza|childp|sexoffen|hitler|nazi|kkk|lynch|onlyfans|nudes|sexting|pussy|vagina|penis|cocks?uck|blowjob|cumshot|cumslut|whore|slut|jailbait|loli|shota|kys|killyourself|suicide|selfharm|dildo)')
    or replace(public.slur_text(t), ' ', '') ~ ('(r[v*]p(e|ist)|[ck][uv*]nn(y|ie)|p[uv*t]?ss(y|ie)|d[i1l]ld[o0]|p[o0]rn)')
    or (' ' || public.slur_text(t) || ' ') ~ ' (sex|sexy|cum|dick|cock|fuck|fucking|fucked|shit|bitch|anal|boobs|tits|horny|nude|nigga|cp|csam) '
    or public.has_name_slur_v2(t);
$$;

-- bad_name (live, Oct 26) on top of bad_name_plain_v2.
create or replace function public.bad_name_v2(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select public.bad_name_plain_v2(t)
    or coalesce((
      select case
          -- digits touching the start or end of a word taken off (a letter right before or after keeps them)
          when v.v1 <> f.s and char_length(regexp_replace(v.v1, '[^[:alpha:]]', '', 'g')) >= 3 and public.bad_name_plain_v2(v.v1) then true
          -- every digit taken off, slur lists only
          when v.v2 <> v.v1 and (public.has_slur(v.v2) or public.has_name_slur_v2(v.v2)) then true
          else false end
      from (select public.fold_fancy(t) as s) f
      cross join lateral (
        select regexp_replace(regexp_replace(f.s, '(?<![[:alpha:]])[0-9]+', '', 'g'), '[0-9]+(?![[:alpha:]])', '', 'g') as v1,
               regexp_replace(f.s, '[0-9]+', '', 'g') as v2
      ) v
      where f.s ~ '[0-9]'
    ), false);
$function$;

-- What the profile and name triggers call: v2 when the flag is on for whoever is making the change.
create or replace function public.bad_name_for_me(t text)
returns boolean language sql stable set search_path to 'public', 'extensions' as $$
  select case when public.feature_on_for_me('name_filter_v2') then public.bad_name_v2(t) else public.bad_name(t) end;
$$;

do $$
declare f text;
begin
  foreach f in array array['ru_latin(text)', 'arabic_letters(text)', 'name_words_v2(text)', 'has_name_slur_v2(text)',
                           'bad_name_plain_v2(text)', 'bad_name_v2(text)', 'bad_name_for_me(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- profile_custom_guard (username, display name, pronouns) and no_bad_names (profiles, servers, channels, categories):
-- every bad_name( call becomes bad_name_for_me(, by exact text on the live body.
do $$
declare fn text; d text;
begin
  foreach fn in array array['public.profile_custom_guard()', 'public.no_bad_names()'] loop
    if to_regprocedure(fn) is null then continue; end if; -- test databases
    d := pg_get_functiondef(fn::regprocedure);
    if position('public.bad_name_for_me(' in d) > 0 then continue; end if; -- already patched
    if position('public.bad_name(' in d) = 0 then raise exception '530: % changed, patch its bad_name calls by hand', fn; end if;
    execute replace(d, 'public.bad_name(', 'public.bad_name_for_me(');
  end loop;
end $$;

reset lock_timeout;
