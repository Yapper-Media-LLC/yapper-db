-- 360: Artist badge and perks for community decoration makers (follows 345, flag community_decos).
--   * Badge 'artist': given automatically with someone's first approved decoration or effect (logged as badge_auto);
--     admins can also give or take it (admin_set_badge). It stays when their items are taken down later.
--   * Artists may have 6 waiting for review instead of 3.
--   * my_deco_wearers(): how many people wear each of my community decorations and effects (shown to the artist).
--     Two small partial indexes keep that to the rows that wear a community one.
-- Re-runnable. Locks on profiles wait at most 3 s.
set lock_timeout = '3s';

create index if not exists profiles_community_deco_idx on public.profiles (avatar_deco) where avatar_deco like 'c:%';
create index if not exists profiles_community_fx_idx on public.profiles (profile_effect) where profile_effect like 'c:%';

-- Live text from 340, with 'artist' added to the badges admins hand out.
create or replace function public.admin_set_badge(uid uuid, badge text, on_off boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  if not (public.is_site_admin() or (public.is_site_mod() and badge = 'bug_hunter')) then raise exception 'Admins only'; end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff', 'developer', 'community_manager', 'creator_1', 'creator_2', 'creator_3', 'artist') then
    raise exception 'Unknown badge';
  end if;
  perform public.mod_guard('badge', uid, null);
  if on_off then
    update public.profiles set
      badges = array(select distinct unnest(
        array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (badge = any(tiers) and b = any(tiers) and b <> badge))
        || badge)),
      shown_badge = case when badge = any(tiers) and shown_badge = any(tiers) then badge else shown_badge end
    where id = uid;
  else
    update public.profiles set
      badges = array_remove(badges, badge),
      shown_badge = case when shown_badge = badge then null else shown_badge end
    where id = uid;
  end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;

-- 345's text; artists (badge 'artist') may have 6 waiting.
create or replace function public.submit_community_deco(p_kind text, p_name text, p_path text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := (select auth.uid()); n_wait int; n_all int; nid uuid; max_wait int := 3;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('community_decos') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper.'; end if;
  if p_kind not in ('deco', 'effect') then raise exception 'Pick a decoration or a profile effect'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 2 or length(p_name) > 32 then raise exception 'Give it a name (2 to 32 characters)'; end if;
  if p_path is null or not starts_with(p_path, me::text || '/') then raise exception 'Upload the picture first'; end if;
  -- One person's submissions are counted under a lock on their profile row, so two at once can't both slip past.
  perform 1 from public.profiles where id = me for update;
  if exists (select 1 from public.profiles where id = me and 'artist' = any(coalesce(badges, '{}'))) then max_wait := 6; end if;
  select count(*) filter (where status = 'pending'), count(*) filter (where status in ('pending', 'approved'))
    into n_wait, n_all from public.community_decos where artist_id = me;
  if n_wait >= max_wait then raise exception 'You have % waiting for review already. Wait for those first.', max_wait; end if;
  if n_all >= 25 then raise exception 'You can have up to 25 decorations and effects.'; end if;
  insert into public.community_decos (kind, name, artist_id, path) values (p_kind, p_name, me, p_path) returning id into nid;
  return nid;
end; $$;

-- 345's text; the first approval gives the artist their badge.
create or replace function public.review_community_deco(p_id uuid, p_status text, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos; got int;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  if p_status not in ('approved', 'rejected', 'removed') then raise exception 'Bad status'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  if p_status <> 'approved' and length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
  select * into d from public.community_decos where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if d.artist_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  -- Taken down (by the artist, or its picture removed by staff): stays down. They can send it in again.
  if d.status = 'removed' then raise exception 'That one was taken down'; end if;
  if p_status = 'approved' and not public.media_ok('avatars', d.path) then raise exception 'Its picture didn''t pass the check'; end if;
  update public.community_decos set status = p_status, review_note = p_note, reviewed_by = (select auth.uid()), reviewed_at = now()
    where id = p_id;
  if d.status = 'approved' and p_status <> 'approved' then perform public.community_deco_unwear(d.path); end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values ((select auth.uid()), 'deco_' || p_status, d.artist_id, left(d.name || case when p_note <> '' then ': ' || p_note else '' end, 300));
  -- Only on a real approval (approving one that's already approved can't hand back a badge an admin took away), never
  -- to someone banned, and a profile the guards won't save (a stored name today's rules refuse) doesn't block it.
  if p_status = 'approved' and d.status <> 'approved' and not public.is_site_banned(d.artist_id) then
    begin
      update public.profiles set badges = array_append(coalesce(badges, '{}'), 'artist')
        where id = d.artist_id and not ('artist' = any(coalesce(badges, '{}')));
      get diagnostics got = row_count;
      if got > 0 then
        insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'badge_auto', d.artist_id, 'artist');
        perform public.rt_profile_changed(array[d.artist_id]);
      end if;
    exception when others then
      raise warning 'review_community_deco: artist badge for % not given: %', d.artist_id, sqlerrm;
    end;
  end if;
end; $$;

-- {"<path>": n, ...}: how many profiles wear each of my community decorations and effects right now.
create or replace function public.my_deco_wearers()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (select 'c:' || (select auth.uid())::text || '/' as pre),
  worn as (
    select substr(p.avatar_deco, 3) as path from public.profiles p, mine where p.avatar_deco like 'c:%' and starts_with(p.avatar_deco, mine.pre)
    union all
    select substr(p.profile_effect, 3) from public.profiles p, mine where p.profile_effect like 'c:%' and starts_with(p.profile_effect, mine.pre)
  )
  select coalesce(jsonb_object_agg(path, n), '{}'::jsonb) from (select path, count(*) as n from worn group by path) x;
$$;
revoke execute on function public.my_deco_wearers() from public, anon;
grant execute on function public.my_deco_wearers() to authenticated;
reset lock_timeout;
