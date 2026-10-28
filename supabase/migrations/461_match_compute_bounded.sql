-- 461: match_compute (459) bounded (460 is taken by feat/desktop-gaming). Live, Antic's account took 1.6 s: he is in 20 servers with 100k membership
-- rows, so the servers path alone made 89k candidates, each checked against blocks/bans/friends/settings, and
-- the output step rescanned those 100k rows once per result. Now:
--   * per shared server at most the 500 most recent joiners count as candidates (server_members_joined_idx);
--     a 5000-member server can't name 5000 people you might click with anyway. Small servers are unchanged.
--   * shared items and shared servers are summed per user once (group by), then full-joined; the top 3 items
--     and top 2 server names come out of the same aggregate.
--   * the filters run on the 200 best-scored candidates only, then the top p_limit are returned.
--   * friendships are probed through friendships_pair_idx (least, greatest): one lookup per candidate instead
--     of a bitmap over all of your requests.
-- Same scoring and the same exclusions as 459; tests/sql/stage459.test.mjs runs this file on top of 459.
-- Re-runnable (create or replace).

create or replace function public.match_compute(p_user uuid, p_limit int default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  bot_ids uuid[] := '{}';
  res jsonb;
begin
  if p_user is null then return '[]'::jsonb; end if;
  p_limit := least(greatest(coalesce(p_limit, 20), 1), 50);
  if to_regclass('public.bots') is not null then
    execute 'select coalesce(array_agg(id), ''{}'') from public.bots' into bot_ids;
  end if;

  with mine as materialized (
    select i.source, i.kind, i.item_id, i.title, i.weight
    from public.media_interests i
    where i.user_id = p_user and public.interest_ok(p_user, i.source)
  ),
  -- How many users have each of my items (stops counting past the cap: a very common item is skipped anyway).
  pop as materialized (
    select m.source, m.kind, m.item_id,
           (select count(*) from (select 1 from public.media_interests i
                                  where i.source = m.source and i.kind = m.kind and i.item_id = m.item_id limit 2001) z) as n
    from mine m
  ),
  -- Whose links count (interest_ok as a set: one small scan and a hash join, not a call per row).
  vis as materialized (
    select l.user_id, l.source from public.media_links l
    where l.is_public and not coalesce((l.prefs ->> 'hidden')::boolean, false)
    union all
    select s.user_id, 'steam' from public.steam_links s
    where s.games_public and not coalesce((s.prefs ->> 'hidden')::boolean, false)
      and coalesce((s.prefs ->> 'show_games')::boolean, true)
  ),
  shared as (
    select o.user_id, m.kind, m.title, (m.weight * o.weight) / ln(1 + p.n) as pts
    from mine m
    join pop p on p.source = m.source and p.kind = m.kind and p.item_id = m.item_id
    join public.media_interests o on o.source = m.source and o.kind = m.kind and o.item_id = m.item_id and o.user_id <> p_user
    join vis v on v.user_id = o.user_id and v.source = o.source
    where p.n <= 2000
  ),
  shared_u as (
    select s.user_id, sum(s.pts) as pts, count(*) as n,
           (array_agg(jsonb_build_object('kind', s.kind, 'title', s.title) order by s.pts desc))[1:3] as top
    from shared s group by s.user_id
  ),
  -- Shared servers: the 500 most recent joiners of each, 0.5 / ln(1 + members) each.
  srv as (
    select sm.user_id, s.name, 0.5 / ln(1 + greatest(s.member_count, 2)) as pts
    from public.server_members ms
    join public.servers s on s.id = ms.server_id
    cross join lateral (
      select m.user_id from public.server_members m
      where m.server_id = s.id and m.user_id <> p_user
      order by m.joined_at desc
      limit 500
    ) sm
    where ms.user_id = p_user
  ),
  srv_u as (
    select z.user_id, sum(z.pts) as pts, count(*) as n, (array_agg(z.name order by z.pts desc))[1:2] as top
    from srv z group by z.user_id
  ),
  cand as (
    select coalesce(a.user_id, b.user_id) as user_id, coalesce(a.pts, 0) + coalesce(b.pts, 0) as score,
           coalesce(a.n, 0) as items_n, coalesce(a.top, '{}'::jsonb[]) as items,
           coalesce(b.n, 0) as servers_n, coalesce(b.top, '{}'::text[]) as servers
    from shared_u a full join srv_u b on b.user_id = a.user_id
  ),
  best as (
    select c.* from cand c where c.user_id <> all (bot_ids)
    order by c.score desc, c.user_id limit 200
  ),
  ok as (
    select c.*
    from best c
    where not exists (select 1 from public.blocks b where (b.blocker = p_user and b.blocked = c.user_id) or (b.blocker = c.user_id and b.blocked = p_user))
      and not exists (select 1 from public.site_bans sb where sb.user_id = c.user_id)
      and not exists (select 1 from public.friendships f
                      where least(f.requester, f.addressee) = least(p_user, c.user_id)
                        and greatest(f.requester, f.addressee) = greatest(p_user, c.user_id))
      and coalesce((select ms.suggest_me from public.match_settings ms where ms.user_id = c.user_id), true)
    order by c.score desc, c.user_id
    limit p_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', o.user_id,
      'score', round(o.score::numeric, 3),
      'items', to_jsonb(o.items),
      'items_n', o.items_n,
      'servers', to_jsonb(o.servers),
      'servers_n', o.servers_n
    ) order by o.score desc, o.user_id), '[]'::jsonb)
  into res
  from ok o;
  return res;
end $$;
revoke all on function public.match_compute(uuid, int) from public, anon, authenticated;
grant execute on function public.match_compute(uuid, int) to service_role;
