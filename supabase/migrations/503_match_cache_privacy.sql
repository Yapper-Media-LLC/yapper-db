-- 503: "People you might click with" forgets people as soon as their privacy changes (security pass 2, N5).
-- Saved suggestion lists (match_cache, kept 6 hours) were rechecked for blocks, bans, friends and the opt-out on
-- read, but not for a connection made hidden / private or disconnected, nor a server someone left: for up to 6 hours
-- they still showed up with that interest or server, and sees_user still let the list's owner open their card.
-- Now any list that names such a person is marked stale (computed_at -infinity), so it's rebuilt on the next open and
-- stops counting for sees_user at once; the person's own list too. sees_user also checks the flag again.
-- match_cache is small (about 1,000 rows, 2 MB), so marking is a scan of it; server leaves are batched per statement
-- and a big delete (a server removed) marks every fresh list in one update. Re-runnable, no data changed.

/** Mark stale every saved list that names one of these people, and their own lists. */
create or replace function public.match_cache_forget(p_users uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_users is null or cardinality(p_users) = 0 then return; end if;
  if cardinality(p_users) > 50 then
    -- A server removed or a mass kick: cheaper to rebuild every fresh list than to look for each person.
    update public.match_cache set computed_at = '-infinity' where computed_at > now() - interval '6 hours';
    return;
  end if;
  -- Only lists that still count (under 6 hours old): older ones are rebuilt on open and ignored by sees_user anyway.
  update public.match_cache c set computed_at = '-infinity'
   where c.computed_at > now() - interval '6 hours'
     and (c.user_id = any (p_users)
          or exists (select 1 from jsonb_array_elements(c.results) e where e ->> 'user_id' = any (p_users::text[])));
end $$;
revoke all on function public.match_cache_forget(uuid[]) from public, anon, authenticated;

-- A connection hidden, made private, unverified or removed.
create or replace function public.match_cache_link_changed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.match_cache_forget(array[coalesce(old.user_id, new.user_id)]);
  return null;
end $$;
revoke all on function public.match_cache_link_changed() from public, anon, authenticated;

-- Updates count only when the connection goes from counting for matches to not counting (same test as match_compute's
-- vis): refreshes and pin edits rewrite these columns all the time and must not throw lists away.
-- media_links.verified (Last.fm sign-in, 467) is live but comes from another branch: part of the test when it's there.
do $$
declare cols text := 'is_public, prefs'; lastfm text := '';
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'media_links' and column_name = 'verified') then
    cols := cols || ', verified';
    lastfm := ' and (%1$s.source <> ''lastfm'' or %1$s.verified)';
  end if;
  execute format('create or replace trigger match_cache_media_link after update of %s on public.media_links
    for each row when (%s and not %s) execute function public.match_cache_link_changed()', cols,
    format('(old.is_public and not coalesce((old.prefs ->> ''hidden'')::boolean, false)' || format(lastfm, 'old') || ')'),
    format('(new.is_public and not coalesce((new.prefs ->> ''hidden'')::boolean, false)' || format(lastfm, 'new') || ')'));
end $$;
create or replace trigger match_cache_media_link_gone after delete on public.media_links
  for each row execute function public.match_cache_link_changed();
create or replace trigger match_cache_steam_link after update of games_public, prefs on public.steam_links
  for each row when (
    (old.games_public and not coalesce((old.prefs ->> 'hidden')::boolean, false) and coalesce((old.prefs ->> 'show_games')::boolean, true))
    and not (new.games_public and not coalesce((new.prefs ->> 'hidden')::boolean, false) and coalesce((new.prefs ->> 'show_games')::boolean, true)))
  execute function public.match_cache_link_changed();
create or replace trigger match_cache_steam_link_gone after delete on public.steam_links
  for each row execute function public.match_cache_link_changed();

-- Someone left (or was removed from) a server: once per statement, whatever the number of rows.
create or replace function public.match_cache_left_server()
returns trigger language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  select array_agg(distinct o.user_id) into ids from gone o;
  perform public.match_cache_forget(ids);
  return null;
end $$;
revoke all on function public.match_cache_left_server() from public, anon, authenticated;

create or replace trigger match_cache_server_left after delete on public.server_members
  referencing old table as gone for each statement execute function public.match_cache_left_server();

-- sees_user as live (458/459) with the flag checked again for the suggestions branch.
create or replace function public.sees_user(target uuid)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select target = auth.uid()
    or exists (select 1 from public.friendships f
               where (f.requester = auth.uid() and f.addressee = target) or (f.addressee = auth.uid() and f.requester = target))
    or exists (select 1 from public.channel_members a
               join public.channel_members b on b.channel_id = a.channel_id and b.user_id = target
               where a.user_id = auth.uid())
    or exists (select 1 from public.server_members m where m.user_id = target and m.server_id in (select public.my_server_ids()))
    or exists (select 1 from public.match_cache c where c.user_id = auth.uid()
               and c.computed_at > now() - interval '6 hours'
               and c.results @> jsonb_build_array(jsonb_build_object('user_id', target::text))
               and not public.is_blocked_between(auth.uid(), target)
               and coalesce((select ms.suggest_me from public.match_settings ms where ms.user_id = target), true)
               and public.feature_on_for_me('interest_matches'));
$function$;
