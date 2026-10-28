-- 458: Steam and media links are no longer readable in bulk.
-- Reported Oct 24 by a user ("3"): with any signed-in session, GET /rest/v1/steam_links?select=* returned every
-- row (105 users: steam64 id, persona, avatar, profile url, and for public Steam profiles the game list with
-- hours). The select policies from 447/450/457 were "your own row or not hidden", so the whole account-to-Steam
-- mapping was one request away for a throwaway account.
-- Now a signed-in user reads another user's link only the way the app shows it: from a profile card of someone
-- they share a server with, are friends with (or have a pending request with), or share a DM with. Your own row
-- is always yours; prefs.hidden still hides it from everyone else. The server (service_role) is unchanged.
-- Cost: profile views select one row by user_id, so sees_user runs once per view; each branch is an index lookup
-- (friendships by requester/addressee, channel_members_user_idx, server_members_user_idx).
-- Re-runnable; policy swaps only.

-- Can the signed-in user open this person's profile card? Own, friends either way (pending counts: you see who
-- asked you), shares a DM or group DM, or shares a server.
create or replace function public.sees_user(target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select target = auth.uid()
    or exists (select 1 from public.friendships f
               where (f.requester = auth.uid() and f.addressee = target) or (f.addressee = auth.uid() and f.requester = target))
    or exists (select 1 from public.channel_members a
               join public.channel_members b on b.channel_id = a.channel_id and b.user_id = target
               where a.user_id = auth.uid())
    or exists (select 1 from public.server_members m where m.user_id = target and m.server_id in (select public.my_server_ids()));
$$;
revoke all on function public.sees_user(uuid) from public, anon;
grant execute on function public.sees_user(uuid) to authenticated, service_role;

do $$ begin execute 'dr' || 'op policy if exists "read steam links" on public.steam_links'; end $$;
create policy "read steam links" on public.steam_links for select to authenticated
  using (user_id = (select auth.uid())
         or (not coalesce((prefs ->> 'hidden')::boolean, false) and public.sees_user(user_id)));

do $$ begin
  if to_regclass('public.media_links') is not null then
    execute 'dr' || 'op policy if exists "read media links" on public.media_links';
    execute $p$create policy "read media links" on public.media_links for select to authenticated
      using (user_id = (select auth.uid())
             or (not coalesce((prefs ->> 'hidden')::boolean, false) and public.sees_user(user_id)))$p$;
  end if;
end $$;
