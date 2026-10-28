-- 444: Bot boosts (flag bot_promoted, like the Promoted spots in 441/443). Same as Discovery boosts for servers:
-- ×2 Boost / ×4 Super Boost / ×8 Mega Boost for 7 days, the bot's server count times the tier in the "Most used"
-- order of /bots, with a guaranteed place: ×2 top 20, ×4 top 10, ×8 top 3 (servers get 100 / 50 / 20; there are
-- ~75 listed bots). Only the biggest live boost counts; buying the same tier again adds 7 days. Boosts live in
-- bot_promotions (kind 'boost', mult); promoted spots are kind 'promote'. Boosts only count for people the flag
-- is on for, and only for bots that bot_promo_ok() allows. public_bots() gains a boost column. Re-runnable.
set lock_timeout = '3s';

alter table public.bot_promotions add column if not exists kind text not null default 'promote' check (kind in ('promote', 'boost'));
alter table public.bot_promotions add column if not exists mult int not null default 1 check (mult in (1, 2, 4, 8));
grant select (kind, mult) on public.bot_promotions to authenticated;

create or replace function public.bot_boost_tiers()
returns int[] language sql immutable as $$ select array[2, 4, 8] $$;

-- Promoted spots only (boosts don't take a spot).
create or replace function public.next_bot_promo_start(bid uuid, p_days int default 7)
returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare t timestamptz; w interval := make_interval(days => greatest(coalesce(p_days, 7), 1)); x timestamptz; nxt timestamptz;
begin
  select greatest(now(), coalesce(max(ends_at), now())) into t from public.bot_promotions where bot_id = bid and kind = 'promote';
  loop
    select pt.x, (select min(o.ends_at) from public.bot_promotions o where o.kind = 'promote' and o.bot_id <> bid and o.starts_at <= pt.x and o.ends_at > pt.x)
      into x, nxt
    from (select t as x union select p.starts_at from public.bot_promotions p
          where p.kind = 'promote' and p.bot_id <> bid and p.starts_at > t and p.starts_at < t + w) pt
    where (select count(distinct o.bot_id) from public.bot_promotions o
           where o.kind = 'promote' and o.bot_id <> bid and o.starts_at <= pt.x and o.ends_at > pt.x) >= public.bot_promo_slots()
    order by pt.x
    limit 1;
    exit when x is null;
    t := nxt;
  end loop;
  return t;
end $$;

-- A boost: starts now, or after a running boost of the same or a bigger tier (buying it again adds days; a cheaper one
-- bought under a bigger one waits for it instead of running unseen).
create or replace function public.book_bot_boost(bid uuid, p_mult int, p_source text, p_event text, p_by uuid default null, p_days int default 7)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_start timestamptz;
begin
  if p_days is null or p_days < 1 or p_days > 60 then raise exception 'Pick 1 to 60 days'; end if;
  if p_mult is null or not (p_mult = any(public.bot_boost_tiers())) then raise exception 'Unknown boost tier'; end if;
  if not exists (select 1 from public.bots where id = bid) then raise exception 'Bot not found'; end if;
  perform pg_advisory_xact_lock(hashtext('bot_promo'));
  select greatest(now(), coalesce(max(ends_at), now())) into v_start from public.bot_promotions
    where bot_id = bid and kind = 'boost' and mult >= p_mult and ends_at > now();
  insert into public.bot_promotions (bot_id, starts_at, ends_at, source, stripe_event, created_by, kind, mult)
  values (bid, v_start, v_start + make_interval(days => p_days), p_source, p_event, p_by, 'boost', p_mult);
  return v_start;
end $$;

-- The "Most used" order of listed bots, with boosts. extra / extra_mult: rank one bot as if it had that boost
-- (for the tier preview). use_boosts false = the plain order (flag off for this visitor).
create or replace function public.bot_order(extra uuid default null, extra_mult int default null, use_boosts boolean default true)
returns table(id uuid, pos bigint, servers bigint, boost int)
language sql stable security definer set search_path = public as $$
  with boosts as (
    select p.bot_id, max(p.mult)::int as b from public.bot_promotions p
    where use_boosts and p.kind = 'boost' and p.starts_at <= now() and p.ends_at > now() and public.bot_promo_ok(p.bot_id)
    group by p.bot_id
  ),
  base as (
    select b.id, lower(b.name) as ln, coalesce(b.real_servers::bigint, public.bot_real_server_count(b.id)) as n,
           greatest(coalesce(bo.b, 1), case when b.id is not distinct from extra then coalesce(extra_mult, 1) else 1 end) as m
    from public.bots b left join boosts bo on bo.bot_id = b.id
    where b.public and b.verified_at is not null
  ),
  organic as (select n, row_number() over (order by n desc, ln) as r from base where m = 1),
  floors as (
    select coalesce((select n from organic where r = 19), -1) as f2,
           coalesce((select n from organic where r = 9), -1) as f4,
           coalesce((select n from organic where r = 2), -1) as f8
  )
  select e.id,
         row_number() over (order by greatest(e.n::numeric * e.m, case e.m when 8 then f.f8 + 0.5 when 4 then f.f4 + 0.5 when 2 then f.f2 + 0.5 else 0 end) desc, e.n desc, e.ln, e.id),
         e.n, case when e.m > 1 then e.m else 0 end
  from base e cross join floors f;
$$;

-- public_bots() with boosts in the "Most used" order and a boost column (0 = none) for the Boosted label.
do $$ begin
  if exists (select 1 from pg_proc where proname = 'public_bots' and pronamespace = 'public'::regnamespace
             and pg_get_function_result(oid) not like '%boost%') then
    execute 'dr' || 'op function public.public_bots(text, text, text, integer, integer)';
  end if;
end $$;
create or replace function public.public_bots(q text default null, cat text default null, sort text default 'popular', lim integer default 60, off integer default 0)
returns table(id uuid, name text, tag text, description text, category text, avatar_path text, support_invite text, servers bigint,
              verified_at timestamptz, created_at timestamptz, owner_name text, boost int)
language plpgsql stable security definer set search_path = public as $$
declare
  term text := nullif(btrim(left(coalesce(q, ''), 64)), '');
  pat text;
  take int := least(greatest(coalesce(lim, 60), 1), 100);
  skip int := least(greatest(coalesce(off, 0), 0), 10000);
  boosts_on boolean;
begin
  if not public.feature_on_for_me('bot_verified') then return; end if;
  boosts_on := public.feature_on_for_me('bot_promoted');
  if term is not null then
    pat := '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  return query
  select b.id, b.name, b.tag, b.description, coalesce(b.category, 'other'), coalesce(bp.avatar_path, b.avatar_path), b.support_invite,
         o.servers, b.verified_at, b.created_at, coalesce(op.display_name, op.username), o.boost
  from public.bot_order(null, null, boosts_on) o
  join public.bots b on b.id = o.id
  join public.profiles bp on bp.id = b.id
  left join public.profiles op on op.id = b.owner_id
  where (coalesce(cat, '') = '' or coalesce(b.category, 'other') = cat)
    and (pat is null or b.name ilike pat escape '\' or b.description ilike pat escape '\')
  order by case when sort = 'new' then b.verified_at end desc nulls last,
           case when sort = 'name' then lower(b.name) end asc,
           o.pos, b.id
  limit take offset skip;
end $$;

-- Where this bot sits now and with each boost (for the Boost cards). Owner or staff only.
create or replace function public.bot_rank_tiers(bid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if (select auth.uid()) is null or not (public.is_staff() or exists (select 1 from public.bots where id = bid and owner_id = (select auth.uid()))) then
    raise exception 'Only the bot’s owner can see this';
  end if;
  return jsonb_build_object(
    'now', (select o.pos from public.bot_order(null, null, true) o where o.id = bid),
    'x2', (select o.pos from public.bot_order(bid, 2, true) o where o.id = bid),
    'x4', (select o.pos from public.bot_order(bid, 4, true) o where o.id = bid),
    'x8', (select o.pos from public.bot_order(bid, 8, true) o where o.id = bid),
    'mult', (select coalesce(max(p.mult), 1) from public.bot_promotions p where p.bot_id = bid and p.kind = 'boost' and p.starts_at <= now() and p.ends_at > now()),
    'until', (select max(p.ends_at) from public.bot_promotions p where p.bot_id = bid and p.kind = 'boost' and p.ends_at > now())
  );
end $$;

create or replace function public.promoted_bots(lim int default 2)
returns table(promo_id uuid, id uuid, name text, tag text, description text, category text, avatar_path text, support_invite text,
              servers bigint, verified_at timestamptz, created_at timestamptz, owner_name text)
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.feature_on_for_me('bot_promoted') or not public.feature_on_for_me('bot_verified') then return; end if;
  return query
  with live as (
    select distinct on (p.bot_id) p.id as pid, p.bot_id
    from public.bot_promotions p
    where p.kind = 'promote' and p.starts_at <= now() and p.ends_at > now()
    order by p.bot_id, p.ends_at desc
  )
  select l.pid, b.id, b.name, b.tag, b.description, coalesce(b.category, 'other'), coalesce(bp.avatar_path, b.avatar_path), b.support_invite,
         coalesce(b.real_servers::bigint, public.bot_real_server_count(b.id)), b.verified_at, b.created_at, coalesce(op.display_name, op.username)
  from live l
  join public.bots b on b.id = l.bot_id
  join public.profiles bp on bp.id = b.id
  left join public.profiles op on op.id = b.owner_id
  where public.bot_promo_ok(b.id)
  order by random()
  limit least(greatest(coalesce(lim, 2), 1), public.bot_promo_slots());
end $$;

create or replace function public.bot_promo_availability(bid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if (select auth.uid()) is null or not (public.is_staff() or exists (select 1 from public.bots where id = bid and owner_id = (select auth.uid()))) then
    raise exception 'Only the bot’s owner can see this';
  end if;
  return jsonb_build_object(
    'ok', public.bot_promo_ok(bid),
    'slots', public.bot_promo_slots(),
    'taken', (select count(distinct bot_id) from public.bot_promotions where kind = 'promote' and starts_at <= now() and ends_at > now()),
    'next', public.next_bot_promo_start(bid),
    'until', (select max(ends_at) from public.bot_promotions where bot_id = bid and kind = 'promote' and ends_at > now())
  );
end $$;

-- Views and clicks are for Promoted spots only.
create or replace function public.bot_promo_event(pids uuid[], kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select auth.uid()) is null or bot_promo_event.kind not in ('view', 'click', 'add') or not public.feature_on_for_me('bot_promoted') then return; end if;
  update public.bot_promotions p set
    views = p.views + (bot_promo_event.kind = 'view')::int,
    clicks = p.clicks + (bot_promo_event.kind = 'click')::int,
    adds = p.adds + (bot_promo_event.kind = 'add')::int
  where p.id = any(pids[1:6]) and p.kind = 'promote' and p.starts_at <= now() and p.ends_at > now() and public.bot_promo_ok(p.bot_id);
end $$;

-- Admin: boost a bot for free.
create or replace function public.admin_boost_bot(bid uuid, days int, p_mult int)
returns timestamptz language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if not public.bot_promo_ok(bid) then raise exception 'Only verified, listed bots can be boosted'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'bot_boost_free', bid, '×' || p_mult || ', ' || days || ' days');
  return public.book_bot_boost(bid, p_mult, 'admin', null, (select auth.uid()), days);
end $$;

-- Mod Center list, now with kind and tier.
do $$ begin
  if exists (select 1 from pg_proc where proname = 'staff_bot_promotions' and pronamespace = 'public'::regnamespace
             and pg_get_function_result(oid) not like '%mult%') then
    execute 'dr' || 'op function public.staff_bot_promotions()';
  end if;
end $$;
create or replace function public.staff_bot_promotions()
returns table(id uuid, bot_id uuid, bot_name text, owner_name text, starts_at timestamptz, ends_at timestamptz, source text,
              views int, clicks int, adds int, ok boolean, kind text, mult int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query
  select p.id, p.bot_id, b.name, coalesce(op.display_name, op.username), p.starts_at, p.ends_at, p.source, p.views, p.clicks, p.adds,
         public.bot_promo_ok(p.bot_id), p.kind, p.mult
  from public.bot_promotions p
  join public.bots b on b.id = p.bot_id
  left join public.profiles op on op.id = b.owner_id
  where p.ends_at > now()
  order by p.kind desc, p.starts_at, p.ends_at
  limit 100;
end $$;

revoke all on function public.book_bot_boost(uuid, int, text, text, uuid, int), public.bot_order(uuid, int, boolean),
  public.public_bots(text, text, text, integer, integer), public.bot_rank_tiers(uuid), public.admin_boost_bot(uuid, int, int),
  public.staff_bot_promotions(), public.promoted_bots(int), public.bot_promo_availability(uuid), public.next_bot_promo_start(uuid, int),
  public.bot_promo_event(uuid[], text) from public, anon, authenticated;
grant execute on function public.book_bot_boost(uuid, int, text, text, uuid, int), public.next_bot_promo_start(uuid, int) to service_role;
grant execute on function public.public_bots(text, text, text, integer, integer), public.promoted_bots(int) to anon, authenticated;
grant execute on function public.bot_rank_tiers(uuid), public.admin_boost_bot(uuid, int, int), public.staff_bot_promotions(),
  public.bot_promo_availability(uuid), public.bot_promo_event(uuid[], text) to authenticated;
reset lock_timeout;
