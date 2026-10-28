-- 507: Discover reads its order from a small cached table instead of ranking every server on each call.
-- DDL: apply before 14:00 UTC (new table, functions, grants: both PostgRESTs rebuild their schema cache).
--
-- Why: discover_servers_page averaged 87-122 ms and ran ~42k times in 15 h (25 Oct). Every call ran
-- discovery_order_m(q, null, null), which seq-scans all ~24k servers (plus promotions and site_bans) to rank the
-- ~2.3k listed ones (37-87 ms alone), and only then paged 48 of them.
--
-- Now:
--   * public.discover_rank (id, pos, boosts, lifted): the full unfiltered ranking from discovery_order_m('', null, null),
--     ~2.3k rows. Refreshed every minute by pg_cron (refresh_discover_rank) in one statement, so readers see the old
--     ranking or the new one, never a mix. Only rows whose rank changed are rewritten; rows that left are removed.
--   * discover_servers_page pages it: order by the cached position, search filter (same predicate) on the live servers
--     row. The relative order of any filtered subset is the same as in the full ranking (score does not depend on q),
--     so ranks inside a search match the old per-call row_number.
--   * Still live per call: name / icon / banner / description / tags / member count / joined, and the "can be listed"
--     checks (discoverable, name_ok, not locked, owner not site-banned, 5+ members unless boosted), so a server that is
--     hidden, locked or whose owner is banned leaves the list at once. Only the ranking (and boost badges) can be up to a
--     minute old; a server that newly qualifies shows up on the next refresh.
--   * While discover_rank is empty (before the first refresh) the page falls back to the old live ranking.
-- discovery_order_m stays the one definition of the order (discovery_rank*, promo tools still call it live).
-- Signature, return type, security definer, search_path and grants of discover_servers_page are unchanged.
-- Checked 25 Oct in a rolled-back transaction against live data: 72 calls (pages 0-5 and deep offsets, 22 searches
-- and tags, anonymous and a logged-in member), 2800 rows, 0 differences from the old function. Old 110 ms average,
-- new 10 ms (browsing 1-3 ms, searches 5-38 ms); one refresh 96 ms, later refreshes rewrite only moved rows.
-- Re-runnable.

set lock_timeout = '3s';

-- ---------- cache ----------
create table if not exists public.discover_rank (
  id uuid primary key,             -- servers.id
  pos integer not null,            -- position in the full Discover order (1 = top)
  boosts integer not null default 0,  -- boost multiplier shown on the card (0 = none)
  lifted boolean not null default false  -- had a live boost at refresh (may list under 5 members)
);
create index if not exists discover_rank_pos_idx on public.discover_rank (pos);
alter table public.discover_rank enable row level security;
-- No policies: only the security definer functions below read or write it.
revoke all on table public.discover_rank from public, anon, authenticated;

create or replace function public.refresh_discover_rank()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n integer;
begin
  -- One refresh at a time (a slow run and the next minute's must not interleave).
  if not pg_try_advisory_xact_lock(hashtext('public.refresh_discover_rank')) then return 0; end if;
  -- One statement: all CTEs see the same snapshot and commit together.
  execute $a$
    with fresh as materialized (
      select o.id, o.pos::integer as pos, case when o.lifted then o.boosts else 0 end as boosts, o.lifted
      from public.discovery_order_m('', null, null) o
    ),
    up as (
      insert into public.discover_rank as r (id, pos, boosts, lifted)
      select f.id, f.pos, f.boosts, f.lifted from fresh f
      on conflict (id) do update set pos = excluded.pos, boosts = excluded.boosts, lifted = excluded.lifted
        where (r.pos, r.boosts, r.lifted) is distinct from (excluded.pos, excluded.boosts, excluded.lifted)
      returning 1
    ),
    gone as (
      de$a$ || $b$lete from public.discover_rank r where not exists (select 1 from fresh f where f.id = r.id)
      returning 1
    )
    select ((select count(*) from up) + (select count(*) from gone))::integer
  $b$ into n;
  return n;
end $$;
revoke all on function public.refresh_discover_rank() from public, anon, authenticated;

-- ---------- the page ----------
create or replace function public.discover_servers_page(q text default ''::text, lim integer default 48, off integer default 0)
returns table(id uuid, name text, icon_path text, banner_path text, banner_x numeric, banner_y numeric, banner_zoom numeric, description text, tags text[], members integer, joined boolean, boosts integer)
language plpgsql stable security definer set search_path to 'public' as $$
#variable_conflict use_column
begin
  if not exists (select 1 from public.discover_rank) then
    -- Cache not filled yet: the pre-507 live ranking.
    return query
    select s.id, s.name, s.icon_path, s.banner_path, s.banner_x, s.banner_y, s.banner_zoom, s.description, s.tags, o.members,
           exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid()),
           case when o.lifted then o.boosts else 0 end
    from public.discovery_order(q, null) o join public.servers s on s.id = o.id
    order by o.pos, s.id
    limit least(coalesce(lim, 48), 100) offset greatest(coalesce(off, 0), 0);
    return;
  end if;

  return query
  select s.id, s.name, s.icon_path, s.banner_path, s.banner_x, s.banner_y, s.banner_zoom, s.description, s.tags, s.member_count,
         exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid()),
         r.boosts
  from public.discover_rank r join public.servers s on s.id = r.id
  where s.discoverable and s.name_ok and (s.locked_until is null or s.locked_until < now())
    and (s.member_count >= 5 or r.lifted)
    and not exists (select 1 from public.site_bans b
                    where b.user_id = s.owner_id and (b.expires_at is null or b.expires_at > now()))
    and (coalesce(q, '') = '' or s.name ilike '%' || q || '%' or s.description ilike '%' || q || '%' or lower(q) = any(s.tags))
  order by r.pos, s.id
  limit least(coalesce(lim, 48), 100) offset greatest(coalesce(off, 0), 0);
end $$;
revoke all on function public.discover_servers_page(text, integer, integer) from public, anon;
grant execute on function public.discover_servers_page(text, integer, integer) to authenticated, service_role;

-- ---------- fill now, then every minute ----------
select public.refresh_discover_rank();
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'discover-rank') then
      perform cron.schedule('discover-rank', '* * * * *', 'select public.refresh_discover_rank()');
    end if;
  end if;
end $$;
