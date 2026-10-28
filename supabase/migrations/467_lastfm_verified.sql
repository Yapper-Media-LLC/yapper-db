-- 467: Last.fm links must be proven (flag media_connections, 457).
-- Until now Last.fm was linked by typing a username, so anyone could show someone else's Last.fm on their profile
-- (a user linked "tobyfox"). Linking is now Last.fm's own sign-in (web auth + auth.getSession, app/api/lastfm/*),
-- and the server saves every new link with verified = true.
-- * media_links.verified: true = linked through the site's sign-in. Existing rows stay null (no data is changed).
--   AniList and Trakt were always signed in, so only Last.fm cares about it.
-- * A Last.fm link that isn't verified (typed in before this) is only visible to its owner, counts for nobody in
--   matching (interest_ok, match_compute) and isn't refreshed any more (server code). Settings asks the owner to
--   sign in to Last.fm; re-linking the same account through sign-in sets verified and it shows again.
-- * One verified Last.fm account per Yapin' account, like AniList and Trakt (457's index leaves Last.fm out). An
--   old typed-in row of the same name never blocks the real owner.
-- Re-runnable. The match_compute change is an in-place patch of 461's text and fails loudly if the live body differs.

alter table public.media_links add column if not exists verified boolean;

create unique index if not exists media_links_lastfm_verified_uniq on public.media_links (account_id)
  where source = 'lastfm' and verified;

-- 458's read policy plus: someone else's Last.fm row only when it's verified.
do $$ begin
  execute 'dr' || 'op policy if exists "read media links" on public.media_links';
  execute $p$create policy "read media links" on public.media_links for select to authenticated
    using (user_id = (select auth.uid())
           or (not coalesce((prefs ->> 'hidden')::boolean, false)
               and (source <> 'lastfm' or verified)
               and public.sees_user(user_id)))$p$;
end $$;

-- 459's interest_ok plus the same rule.
create or replace function public.interest_ok(p_user uuid, p_source text)
returns boolean language sql stable security definer set search_path = public as $$
  select case when p_source = 'steam'
    then exists (select 1 from public.steam_links s where s.user_id = p_user and s.games_public
                 and not coalesce((s.prefs ->> 'hidden')::boolean, false)
                 and coalesce((s.prefs ->> 'show_games')::boolean, true))
    else exists (select 1 from public.media_links l where l.user_id = p_user and l.source = p_source and l.is_public
                 and (l.source <> 'lastfm' or l.verified)
                 and not coalesce((l.prefs ->> 'hidden')::boolean, false))
  end;
$$;
revoke all on function public.interest_ok(uuid, text) from public, anon, authenticated;
grant execute on function public.interest_ok(uuid, text) to service_role;

-- match_compute's "whose links count" set (461): unverified Last.fm links count for nobody.
do $$
declare
  d text := pg_get_functiondef('public.match_compute(uuid, int)'::regprocedure);
  old text := 'where l.is_public and not coalesce((l.prefs ->> ''hidden'')::boolean, false)';
begin
  if position('467:' in d) > 0 then return; end if;
  if position(old in d) = 0 then raise exception '467: match_compute is not 461''s text, patch it by hand'; end if;
  execute replace(d, old,
    'where l.is_public and (l.source <> ''lastfm'' or l.verified) /* 467: typed-in Last.fm names count for nobody */'
    || ' and not coalesce((l.prefs ->> ''hidden'')::boolean, false)');
end $$;
revoke all on function public.match_compute(uuid, int) from public, anon, authenticated;
grant execute on function public.match_compute(uuid, int) to service_role;

-- Saved suggestion lists may lean on a typed-in Last.fm: the next open recomputes (as 463 did).
update public.match_cache set computed_at = now() - interval '7 hours' where computed_at > now() - interval '7 hours';
