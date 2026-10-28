-- 459: "People you might click with" (flag interest_matches, test). Suggests people who share your interests
-- (the media_interests rows the AniList, Last.fm and Trakt refreshes write, plus Steam games from now on) and
-- your servers. Antic: "an algorithm that matches people on shared games, anime, music, movies and servers".
--
-- * Steam games join media_interests (source 'steam', kind 'game'): refreshSteam (lib/server/steam.ts) calls
--   steam_save_interests with up to 150 games weighted by hours. media_interests used to have a foreign key to
--   media_links; Steam lives in steam_links, so the key becomes two small cascade triggers (unlink = rows gone).
-- * match_settings: "Suggest me to people with similar interests" (default on). Off = you are in nobody's list.
-- * match_compute(p_user): the scoring. Server only (service_role / called by my_matches).
--     items: for each of your visible interests, everyone else who has it. Points = your weight x their weight
--            / ln(1 + how many users have it), so an obscure anime two people share counts more than Naruto.
--     servers: each server you share, 0.5 / ln(1 + member_count): a 10-person server says more than HQ.
--     Visible = the link is not hidden (prefs.hidden) and the site profile is public (media_links.is_public,
--     steam_links.games_public). Hidden on either side counts for nobody.
--     Out: you, blocked either way, site-banned, bots, friends and pending requests, and people who opted out.
--     Top 20 by score, each with the top 3 shared items and up to 2 shared server names for the "why" line.
-- * my_matches(p_refresh): what the app calls. Flag check, then the cached list (match_cache, per user) when it
--   is under 6 hours old (1 hour with p_refresh), else recompute. Never runs at startup: only when you open
--   Friends > Suggested. On read it drops anyone who opted out, blocked you or became a friend since.
-- * sees_user (458) also lets you read the Steam and media links of people in your current suggestions, so their
--   profile card can show the interests you share.
--
-- Cost (explain (costs off) of the query below in PGlite, 61 users x 40 interests, 83 ms whole function):
--   mine: media_interests by primary key prefix (user_id). pop: one Aggregate over a Bitmap Index Scan on
--   media_interests_item_idx per item of yours (materialized, so it runs once per item, stops at 2001 rows).
--   vis: one scan of media_links and steam_links (a few hundred rows, linked users only) hash-joined to the
--   holders. shared: Index Scan on media_interests_item_idx per item. srv: server_members by user
--   (server_members_user_idx) then by server (primary key),
--   servers by primary key. Filters (blocks, site_bans, friendships, match_settings): per-candidate index
--   lookups, at most p_limit after the sort. Never touches profiles. Items held by more than 2000 users are
--   skipped: they say nothing and would cost the most.
-- Re-runnable. DDL: media_interests constraints, two triggers, two small tables, functions.

-- ---------- Steam games as interests ----------
do $$ begin
  execute 'alter table public.media_interests dr' || 'op constraint if exists media_interests_kind_check';
  execute 'alter table public.media_interests dr' || 'op constraint if exists media_interests_source_check';
  execute 'alter table public.media_interests dr' || 'op constraint if exists media_interests_user_id_source_fkey';
end $$;
alter table public.media_interests add constraint media_interests_kind_check
  check (kind in ('anime', 'manga', 'artist', 'track', 'movie', 'show', 'game'));
alter table public.media_interests add constraint media_interests_source_check
  check (source in ('anilist', 'lastfm', 'trakt', 'steam'));

-- The foreign key's job, now that one source has no media_links row: unlinking removes the interests.
create or replace function public.media_interests_unlink() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'steam_links' then
    execute 'de' || 'lete from public.media_interests where user_id = $1 and source = ''steam''' using old.user_id;
  else
    execute 'de' || 'lete from public.media_interests where user_id = $1 and source = $2' using old.user_id, old.source;
  end if;
  return old;
end $$;
do $$ begin
  execute 'dr' || 'op trigger if exists media_interests_unlink on public.media_links';
  execute 'dr' || 'op trigger if exists media_interests_unlink on public.steam_links';
end $$;
create trigger media_interests_unlink after delete on public.media_links for each row execute function public.media_interests_unlink();
create trigger media_interests_unlink after delete on public.steam_links for each row execute function public.media_interests_unlink();

-- Save one Steam refresh's games as interests. Only while the link still points at p_steam_id (a disconnect or a
-- switch meanwhile wins). p_items: [{item_id, title, weight}], at most 150.
create or replace function public.steam_save_interests(p_user uuid, p_steam_id text, p_items jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) > 150 then
    raise exception 'bad items';
  end if;
  if not exists (select 1 from public.steam_links where user_id = p_user and steam_id = p_steam_id) then return false; end if;
  execute 'de' || 'lete from public.media_interests where user_id = $1 and source = ''steam''' using p_user;
  insert into public.media_interests (user_id, source, kind, item_id, title, weight)
  select p_user, 'steam', 'game', i ->> 'item_id', left(coalesce(i ->> 'title', ''), 200),
         least(1, greatest(0, coalesce((i ->> 'weight')::real, 0)))
  from jsonb_array_elements(p_items) i
  where i ->> 'item_id' ~ '^[0-9]{1,12}$'
  on conflict do nothing;
  return true;
end $$;
revoke all on function public.steam_save_interests(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.steam_save_interests(uuid, text, jsonb) to service_role;

-- ---------- Opt out ----------
create table if not exists public.match_settings (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  suggest_me boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.match_settings enable row level security;
do $$ begin execute 'dr' || 'op policy if exists "own match settings" on public.match_settings'; end $$;
create policy "own match settings" on public.match_settings for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.match_settings from public, anon, authenticated;
grant select, insert, update on public.match_settings to authenticated;
grant all on public.match_settings to service_role;

-- ---------- Cache ----------
create table if not exists public.match_cache (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  computed_at timestamptz not null default now(),
  results jsonb not null default '[]' check (jsonb_typeof(results) = 'array')
);
alter table public.match_cache enable row level security;
revoke all on public.match_cache from public, anon, authenticated;
grant all on public.match_cache to service_role;

-- Does this user's link for this source count for matching? Not hidden, public on the site, and for Steam the
-- games are shown on the card (prefs.show_games).
create or replace function public.interest_ok(p_user uuid, p_source text)
returns boolean language sql stable security definer set search_path = public as $$
  select case when p_source = 'steam'
    then exists (select 1 from public.steam_links s where s.user_id = p_user and s.games_public
                 and not coalesce((s.prefs ->> 'hidden')::boolean, false)
                 and coalesce((s.prefs ->> 'show_games')::boolean, true))
    else exists (select 1 from public.media_links l where l.user_id = p_user and l.source = p_source and l.is_public
                 and not coalesce((l.prefs ->> 'hidden')::boolean, false))
  end;
$$;
revoke all on function public.interest_ok(uuid, text) from public, anon, authenticated;
grant execute on function public.interest_ok(uuid, text) to service_role;

-- ---------- The scoring ----------
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
  -- Whose links count (interest_ok as a set, so it is one small scan and a hash join, not a call per row).
  vis as materialized (
    select l.user_id, l.source from public.media_links l
    where l.is_public and not coalesce((l.prefs ->> 'hidden')::boolean, false)
    union all
    select s.user_id, 'steam' from public.steam_links s
    where s.games_public and not coalesce((s.prefs ->> 'hidden')::boolean, false)
      and coalesce((s.prefs ->> 'show_games')::boolean, true)
  ),
  shared as (
    select o.user_id, m.source, m.kind, m.title, (m.weight * o.weight) / ln(1 + p.n) as pts
    from mine m
    join pop p on p.source = m.source and p.kind = m.kind and p.item_id = m.item_id
    join public.media_interests o on o.source = m.source and o.kind = m.kind and o.item_id = m.item_id and o.user_id <> p_user
    join vis v on v.user_id = o.user_id and v.source = o.source
    where p.n <= 2000
  ),
  srv as (
    select sm.user_id, s.name, 0.5 / ln(1 + greatest(s.member_count, 2)) as pts
    from public.server_members ms
    join public.servers s on s.id = ms.server_id
    join public.server_members sm on sm.server_id = ms.server_id and sm.user_id <> p_user
    where ms.user_id = p_user
  ),
  cand as (
    select x.user_id, sum(x.pts) as score
    from (select user_id, pts from shared union all select user_id, pts from srv) x
    group by x.user_id
  ),
  ok as (
    select c.user_id, c.score
    from cand c
    where c.user_id <> all (bot_ids)
      and not exists (select 1 from public.blocks b where (b.blocker = p_user and b.blocked = c.user_id) or (b.blocker = c.user_id and b.blocked = p_user))
      and not exists (select 1 from public.site_bans sb where sb.user_id = c.user_id)
      and not exists (select 1 from public.friendships f where (f.requester = p_user and f.addressee = c.user_id) or (f.requester = c.user_id and f.addressee = p_user))
      and coalesce((select ms.suggest_me from public.match_settings ms where ms.user_id = c.user_id), true)
    order by c.score desc, c.user_id
    limit p_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', o.user_id,
      'score', round(o.score::numeric, 3),
      'items', (select coalesce(jsonb_agg(jsonb_build_object('kind', t.kind, 'title', t.title) order by t.pts desc), '[]'::jsonb)
                from (select s.kind, s.title, s.pts from shared s where s.user_id = o.user_id order by s.pts desc limit 3) t),
      'items_n', (select count(*) from shared s where s.user_id = o.user_id),
      'servers', (select coalesce(jsonb_agg(t.name order by t.pts desc), '[]'::jsonb)
                  from (select z.name, z.pts from srv z where z.user_id = o.user_id order by z.pts desc limit 2) t),
      'servers_n', (select count(*) from srv z where z.user_id = o.user_id)
    ) order by o.score desc), '[]'::jsonb)
  into res
  from ok o;
  return res;
end $$;
revoke all on function public.match_compute(uuid, int) from public, anon, authenticated;
grant execute on function public.match_compute(uuid, int) to service_role;

-- What the app calls (Friends > Suggested). Your own list only: there is no user parameter.
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
  if row.user_id is null or row.computed_at < now() - (case when p_refresh then interval '1 hour' else interval '6 hours' end) then
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

-- 458's sees_user, plus the people in your current suggestions (so their card shows what you share): only while
-- the list is fresh (6 h, same as my_matches), and not once they opted out or either of you blocked the other.
create or replace function public.sees_user(target uuid)
returns boolean language sql stable security definer set search_path = public as $$
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
               and coalesce((select ms.suggest_me from public.match_settings ms where ms.user_id = target), true));
$$;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('interest_matches', 'Suggested people',
        'Friends > Suggested: people who share your games, anime, music, movies and servers, and a Settings toggle to stay out of it', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
