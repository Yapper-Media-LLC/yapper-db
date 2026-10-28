-- Artist badge missing after a decoration was approved (bug reports Oct 22, 3 of them; 18 artists in all).
--
-- review_community_deco gives the artist the Artist badge with an update on their profile. That update goes through
-- the profiles triggers, and require_mfa there checks the session of whoever is running it: a reviewer with 2FA
-- set up but a session that isn't 2FA-verified (aal1) gets 'Finish two-factor sign-in first.'. The function catches
-- that on purpose (the badge must never block a review), so the decoration went live and the badge silently didn't
-- come. That is what happened to the batch approvals on Oct 22 at 08:42 and 18:06 UTC (postgres log:
-- "review_community_deco: artist badge for ... not given: Finish two-factor sign-in first.").
--
-- The badge is a consequence of the approval, which itself needs no 2FA step, so it shouldn't depend on the
-- reviewer's sign-in. The badge update now runs without the caller's JWT (auth.uid() null, as from the SQL editor),
-- which require_mfa and not_site_banned skip; the claims are put back right after (and on an error the
-- subtransaction rolls them back anyway). Nothing else in the function changes.
--
-- Part 2 is a BACKFILL that changes real users' profiles: it gives the Artist badge to everyone with a live
-- (approved) decoration who doesn't have it, unless staff took that badge off them before or they're banned.
-- Antic decides whether to run it. Safe to apply any time; no app deploy needed. Re-runnable.

create or replace function public.review_community_deco(p_id uuid, p_status text, p_note text default '')
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare d public.community_decos; got int; c_sub text; c_claims text; c_claim text;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  if p_status not in ('approved', 'rejected', 'removed') then raise exception 'Bad status'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  if p_status <> 'approved' and length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
  select * into d from public.community_decos where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if d.artist_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if d.status = 'removed' then raise exception 'That one was taken down'; end if;
  if p_status = 'approved' and not public.media_ok('avatars', d.path) then raise exception 'Its picture didn''t pass the check'; end if;
  if p_status = 'approved' and exists (select 1 from public.community_deco_checks c
      where c.deco_id = p_id and c.verdict in ('suspect', 'stolen') and c.cleared_at is null) then
    raise exception 'The auto-check flagged this one. Say why it''s fine first';
  end if;
  update public.community_decos set status = p_status, review_note = p_note, reviewed_by = (select auth.uid()), reviewed_at = now()
    where id = p_id;
  if d.status = 'approved' and p_status <> 'approved' then perform public.community_deco_unwear(d.path); end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values ((select auth.uid()), 'deco_' || p_status, d.artist_id, left(d.name || case when p_note <> '' then ': ' || p_note else '' end, 300));
  if p_status = 'approved' and d.status <> 'approved' and not public.is_site_banned(d.artist_id) then
    begin
      -- 426: without the reviewer's JWT, so their own 2FA state (require_mfa) can't refuse the artist's badge.
      c_sub := current_setting('request.jwt.claim.sub', true);
      c_claims := current_setting('request.jwt.claims', true);
      c_claim := current_setting('request.jwt.claim', true);
      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '', true);
      perform set_config('request.jwt.claim', '', true);
      update public.profiles set badges = array_append(coalesce(badges, '{}'), 'artist')
        where id = d.artist_id and not ('artist' = any(coalesce(badges, '{}')));
      get diagnostics got = row_count;
      perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
      perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);
      perform set_config('request.jwt.claim', coalesce(c_claim, ''), true);
      if got > 0 then
        insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'badge_auto', d.artist_id, 'artist');
        perform public.rt_profile_changed(array[d.artist_id]);
      end if;
    exception when others then
      raise warning 'review_community_deco: artist badge for % not given: %', d.artist_id, sqlerrm;
    end;
  end if;
end; $function$;

-- Part 2, BACKFILL (real users' data, Antic's call): the artists the bug skipped. One profile at a time, so one
-- refused row (a profile guard) can't stop the rest.
do $$
declare r record; done uuid[] := '{}';
begin
  for r in
    select distinct p.id from public.profiles p
    join public.community_decos d on d.artist_id = p.id and d.status = 'approved'
    where not ('artist' = any(coalesce(p.badges, '{}')))
      and not public.is_site_banned(p.id)
      and not exists (select 1 from public.mod_log m where m.target_id = p.id and m.action = 'badge_removed' and m.reason ilike '%artist%')
  loop
    begin
      update public.profiles set badges = array_append(coalesce(badges, '{}'), 'artist')
        where id = r.id and not ('artist' = any(coalesce(badges, '{}')));
      if found then
        insert into public.mod_log (actor, action, target_id, reason) values (null, 'badge_auto', r.id, 'artist (426: missed on approval)');
        done := done || r.id;
      end if;
    exception when others then
      raise warning '426: artist badge for % not given: %', r.id, sqlerrm;
    end;
  end loop;
  if cardinality(done) > 0 then perform public.rt_profile_changed(done); end if;
end $$;
