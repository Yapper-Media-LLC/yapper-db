-- 463: Suggested people, two follow-ups (Antic, Oct 24).
-- * Backfill: Steam games only became interests on refreshes after 459 (19 of 131 links by 11:35 UTC), so game
--   matches were nearly empty. Every public Steam link already caches its top 12 games with hours in
--   steam_links.games, so those become interest rows now, without calling Steam. Only for links that have no
--   'steam' rows yet (a refresh after 459 wrote a longer list, up to 150 games; that one stays). Same weight as
--   lib/server/steam.ts hoursWeight: ln(1 + hours) / ln(201), 200 h or more = 1.
-- * Refresh on Friends > Suggested recomputes when the list is over 5 minutes old (was 1 hour), so pressing it
--   right after linking something shows the change. A normal open still uses the 6 hour cache.
-- * Saved lists from before the backfill are marked stale, so the next open recomputes with games in.
-- Data plus one create or replace. Re-runnable (the insert skips users who already have steam rows).

insert into public.media_interests (user_id, source, kind, item_id, title, weight)
select s.user_id, 'steam', 'game', (g ->> 'app'), left(coalesce(g ->> 'name', ''), 200),
       least(1, greatest(0, ln(1 + greatest(coalesce((g ->> 'hours')::numeric, 0), 0)) / ln(201)))::real
from public.steam_links s
cross join lateral jsonb_array_elements(case when jsonb_typeof(s.games) = 'array' then s.games else '[]'::jsonb end) g
where s.games_public
  and (g ->> 'app') ~ '^[0-9]{1,12}$'
  and coalesce((g ->> 'hours')::numeric, 0) > 0
  and not exists (select 1 from public.media_interests i where i.user_id = s.user_id and i.source = 'steam')
on conflict do nothing;

create or replace function public.my_matches(p_refresh boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  row public.match_cache;
  res jsonb;
begin
  if me is null then return '[]'::jsonb; end if;
  if not public.feature_on_for_me('interest_matches') then
    raise exception 'Not available yet' using errcode = 'P0001';
  end if;
  select * into row from public.match_cache c where c.user_id = me;
  if row.user_id is null or row.computed_at < now() - (case when p_refresh then interval '5 minutes' else interval '6 hours' end) then
    res := public.match_compute(me, 20);
    insert into public.match_cache as c (user_id, computed_at, results) values (me, now(), res)
    on conflict (user_id) do update set computed_at = now(), results = excluded.results;
  else
    res := row.results;
  end if;
  -- Since it was computed: opted out, blocked either way, banned, or became a friend (or asked).
  select coalesce(jsonb_agg(r), '[]'::jsonb) into res
  from jsonb_array_elements(res) r
  where coalesce((select ms.suggest_me from public.match_settings ms where ms.user_id = (r ->> 'user_id')::uuid), true)
    and not public.is_blocked_between(me, (r ->> 'user_id')::uuid)
    and not exists (select 1 from public.site_bans sb where sb.user_id = (r ->> 'user_id')::uuid)
    and not exists (select 1 from public.friendships f
                    where (f.requester = me and f.addressee = (r ->> 'user_id')::uuid) or (f.addressee = me and f.requester = (r ->> 'user_id')::uuid));
  return res;
end $$;
revoke all on function public.my_matches(boolean) from public, anon;
grant execute on function public.my_matches(boolean) to authenticated;

-- Lists saved before the backfill: recompute on the next open.
update public.match_cache set computed_at = now() - interval '7 hours' where computed_at > now() - interval '7 hours';
