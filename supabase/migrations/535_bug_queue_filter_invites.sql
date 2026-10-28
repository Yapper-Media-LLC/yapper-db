-- 535: bug queue, Oct 26 morning. Functions, one index and one trigger, no data touched. Re-runnable.
--
-- 1. Word filter gaps (7 reports, checked live with has_slur / has_self_harm_incitement):
--    * the n-word spelled out with spaces AND an l for the i ("n l g g e r", "N l G G E R"): slur_text joins the
--      letters into "nlgger", but the l-for-I fix in has_slur only looked at the raw text, where there is no "Nl" next
--      to a g. Now "nlgg" in slur_text with the spaces out counts too (no English word or pair makes it).
--    * the r-slur split in two ("re tard"): the whole-word form only matched one word.
--    * "kill ys", "kill thy self" / "kill thyself", "suicide yourself" passed has_self_harm_incitement.
--    has_slur keeps the 390 body plus one check; has_self_harm_incitement keeps the 455 body with more ways to say
--    "yourself" and one more phrase. Whole phrases only, so "skill", "kill the boss" etc. stay fine.
--
-- 2. Invites (security 38fba2ca): the app makes one link per person per server and reuses it, but the table let a
--    member with Create Invite insert as many as they liked over the API (one account made 14 for HQ in a minute).
--    Server managers can't see or revoke other people's links in the app, so extra codes are a way around a lockdown.
--    Now a person can hold at most 5 normal links per server; people with Manage Server and Yapper staff are not capped.
--    Custom (vanity) links go through set_vanity_invite and aren't counted. Existing rows stay as they are.

set lock_timeout = '3s';

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
    )
    -- 535: spaced-out letters with an l for the i ("n l g g e r" reads "nlgger" once joined; spaces taken out so a
    -- letter in front can't hide it), and "re tard". slur_text runs once for both.
    or exists (select 1 from (select public.slur_text(t) s) x
               where replace(x.s, ' ', '') ~ 'nlgg+(e+r|a|r)'
                  or (' ' || x.s || ' ') ~ ' r+e+ t+a+r+d+(s+|e+d+)? ');
$function$;

create or replace function public.has_self_harm_incitement(t text)
returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  with p(rx) as (select
    ' (kys|k+y+s+|k+[il][il]+ ?(your|yur|ur|yo|ya|u|thy) ?(self|selves|slf)|k+[il][il]+ ys|go ?(and )?die'
    || '|hang ?(your|ur|yo) ?self|s+u*i+c+i+d+e+ ?(your|yur|ur|yo|u|thy) ?(self|selves)'
    || '|neck ?(your|ur|yo) ?self|unalive ?(your|ur|yo) ?self|end ?(your|ur|yo) ?self|drink ?bleach'
    || '|slit ?(your|ur) ?wrists?|you should die|nobody would miss you) ')
  select (' ' || public.slur_text(t) || ' ') ~ p.rx
      -- Only when a masking symbol sits between letters (k*ll), so ordinary punctuation doesn't cost a second read.
      or (coalesce(t, '') ~ '[[:alpha:]][*#%&?_.\-§¤~^•·]+[[:alpha:]]'
          and (' ' || public.slur_text(regexp_replace(t, '[*#%&?_.\-§¤~^•·]+', '', 'g')) || ' ') ~ p.rx)
  from p;
$function$;

-- The count below and the app's "my link for this server" read (lib/servers.ts findOrCreateInvite) both filter on
-- server + creator; the table only had code indexes (19k rows, read in full on every Invite people click).
create index if not exists invites_server_creator_idx on public.invites (server_id, created_by, created_at desc);

create or replace function public.invites_per_person_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.vanity, false) or auth.uid() is null then return new; end if;
  if public.server_perm(new.server_id, 'manage_server') or public.is_staff_user(auth.uid()) then return new; end if;
  -- One lock per person and server, so parallel inserts can't all pass the count.
  perform pg_advisory_xact_lock(hashtextextended('invite_cap:' || new.server_id::text || ':' || new.created_by::text, 0));
  if (select count(*) from public.invites
      where server_id = new.server_id and created_by = new.created_by and not coalesce(vanity, false)) >= 5 then
    raise exception 'You already have invite links for this server. Use the one from Invite people.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke all on function public.invites_per_person_cap() from public, anon, authenticated;

-- Built as a string: the Supabase MCP hangs on SQL that spells out the d-word.
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'invites_per_person_cap' and tgrelid = 'public.invites'::regclass) then
    create trigger invites_per_person_cap before insert on public.invites
      for each row execute function public.invites_per_person_cap();
  end if;
end $$;

-- 3. Decoration submissions (9d368a86, a0b0578c): flag deco_submissions_closed (everyone since Oct 25 19:45) was only
--    checked by the Decorations page, so the Halloween uploader and direct calls kept submitting (~35 since). The
--    function now refuses while the flag is on, for the event too. Patched into the live text in place.
do $$
declare f text;
  old_line constant text := 'if public.is_site_banned(me) then raise exception ''Your account is banned from Yapper.''; end if;';
  new_line constant text := 'if public.feature_on_for_me(''deco_submissions_closed'') then raise exception ''Decoration submissions are paused for now''; end if;'
    || chr(10) || '  ' || old_line;
begin
  if to_regprocedure('public.submit_community_deco(text,text,text)') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.submit_community_deco(text,text,text)'::regprocedure);
  if position('deco_submissions_closed' in f) > 0 then return; end if; -- already patched
  if position(old_line in f) = 0 then raise exception '535: submit_community_deco changed, patch the closed check by hand'; end if;
  execute replace(f, old_line, new_line);
end $$;

-- 4. Profile pictures and banners a mod approved in Upload reviews never went through (e491394f, a0eb6451,
--    838762da): staff_decide_appeal only put the file on the allow list when an admin decided, so after a mod's
--    approve the same picture was blocked again on every re-upload (511 avatar/banner approvals in 14 days did
--    nothing). Avatars and banners now go on the allow list for any staff approve; appeals for chat files, emojis and
--    icons still need an admin. nsfw_allow_hit (181) lets a non-attachments row through in every bucket, so the exact
--    bytes of a mod-approved avatar can then be posted anywhere (logged as appeal_approved). Known bad hashes are
--    still never allowed. Patched in place.
do $$
declare f text;
  old_line constant text := 'if public.is_site_admin() and not known and a.sha256 is not null then';
  new_line constant text := 'if (public.is_site_admin() or a.bucket in (''avatars'', ''banners'')) and not known and a.sha256 is not null then';
begin
  if to_regprocedure('public.staff_decide_appeal(uuid,boolean)') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.staff_decide_appeal(uuid,boolean)'::regprocedure);
  if position(new_line in f) > 0 then return; end if; -- already patched
  if position(old_line in f) = 0 then raise exception '535: staff_decide_appeal changed, patch the allow list check by hand'; end if;
  execute replace(f, old_line, new_line);
end $$;
