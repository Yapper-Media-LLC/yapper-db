-- 441: Promoted bots (flag bot_promoted, test). Same model as Promoted servers (085, 088, 292): a bot's owner pays
-- for a 7 day spot at the top of the bot list (/bots), 4 spots at once, later buys queue behind the running ones.
-- Paid through /api/stripe/checkout (kind bot_promote, ref bpromo_<bot id>); the webhook books it with
-- book_bot_promotion (service_role only). Only verified, listed bots whose bot and owner aren't site-banned can be
-- bought for, and only those are shown, so a bot banned mid-promotion just drops out. Staff can end one from
-- Mod Center (logged as bot_promo_ended). Re-runnable.
set lock_timeout = '3s';

create table if not exists public.bot_promotions (
  id uuid primary key default gen_random_uuid(),
  bot_id uuid not null references public.bots(id) on delete cascade,
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  source text not null default 'stripe' check (source in ('stripe', 'admin')),
  stripe_event text unique,
  created_by uuid,
  views int not null default 0,
  clicks int not null default 0,
  adds int not null default 0,
  ended_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists bot_promotions_live on public.bot_promotions (ends_at, starts_at);
create index if not exists bot_promotions_bot on public.bot_promotions (bot_id, ends_at desc);
alter table public.bot_promotions enable row level security;

-- The bot's owner sees its promotions (and the numbers); staff see all. No direct writes.
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bot_promotions' and policyname = 'owners see bot promotions') then
    create policy "owners see bot promotions" on public.bot_promotions for select to authenticated
      using ((select public.is_staff()) or exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = (select auth.uid())));
  end if;
end $$;
revoke all on public.bot_promotions from anon, authenticated;
grant select (id, bot_id, starts_at, ends_at, source, views, clicks, adds, created_at) on public.bot_promotions to authenticated;

create or replace function public.bot_promo_slots()
returns integer language sql immutable as $$ select 4 $$;

-- Can this bot be promoted (and shown as promoted)? Verified, listed, bot and owner not banned, name not blocked.
create or replace function public.bot_promo_ok(bid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select b.public and b.verified_at is not null and not coalesce(b.unlisted, false)
       and not public.is_site_banned(b.id) and not public.is_site_banned(b.owner_id) and not public.bad_name(b.name)
    from public.bots b where b.id = bid), false);
$$;

-- When a new booking for this bot would start: after its own last one, at the first time when fewer than
-- bot_promo_slots() other bots run for the whole p_days window (not just at its start: a promotion staff ended early
-- frees a spot now, but a queued one may still begin inside the window).
create or replace function public.next_bot_promo_start(bid uuid, p_days int default 7)
returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare t timestamptz; w interval := make_interval(days => greatest(coalesce(p_days, 7), 1)); x timestamptz; nxt timestamptz;
begin
  select greatest(now(), coalesce(max(ends_at), now())) into t from public.bot_promotions where bot_id = bid;
  loop
    -- The first moment in [t, t + w) where the spots are full: the count only rises at t or where another one starts.
    select pt.x, (select min(o.ends_at) from public.bot_promotions o where o.bot_id <> bid and o.starts_at <= pt.x and o.ends_at > pt.x)
      into x, nxt
    from (select t as x union select p.starts_at from public.bot_promotions p
          where p.bot_id <> bid and p.starts_at > t and p.starts_at < t + w) pt
    where (select count(distinct o.bot_id) from public.bot_promotions o
           where o.bot_id <> bid and o.starts_at <= pt.x and o.ends_at > pt.x) >= public.bot_promo_slots()
    order by pt.x
    limit 1;
    exit when x is null;
    t := nxt;
  end loop;
  return t;
end $$;

-- The only way rows are made: the Stripe webhook (service_role) and admin_promote_bot.
create or replace function public.book_bot_promotion(bid uuid, p_source text, p_event text, p_by uuid default null, p_days int default 7)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_start timestamptz;
begin
  if p_days is null or p_days < 1 or p_days > 60 then raise exception 'Pick 1 to 60 days'; end if;
  if not exists (select 1 from public.bots where id = bid) then raise exception 'Bot not found'; end if;
  -- One booking at a time (any bot), so two webhooks at once can't both take the last free spot.
  perform pg_advisory_xact_lock(hashtext('bot_promo'));
  v_start := public.next_bot_promo_start(bid, p_days);
  insert into public.bot_promotions (bot_id, starts_at, ends_at, source, stripe_event, created_by)
  values (bid, v_start, v_start + make_interval(days => p_days), p_source, p_event, p_by);
  return v_start;
end $$;

-- Live promoted bots for the top of /bots: random order, at most bot_promo_slots(). Same columns as public_bots() plus promo_id.
create or replace function public.promoted_bots(lim int default 4)
returns table(promo_id uuid, id uuid, name text, tag text, description text, category text, avatar_path text, support_invite text,
              servers bigint, verified_at timestamptz, created_at timestamptz, owner_name text)
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.feature_on_for_me('bot_promoted') or not public.feature_on_for_me('bot_verified') then return; end if;
  return query
  with live as (
    select distinct on (p.bot_id) p.id as pid, p.bot_id
    from public.bot_promotions p
    where p.starts_at <= now() and p.ends_at > now()
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
  limit least(greatest(coalesce(lim, 4), 1), public.bot_promo_slots());
end $$;

-- Count what a promotion got. Views once per visit; signed-in people only, like promo_event.
create or replace function public.bot_promo_event(pids uuid[], kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select auth.uid()) is null or kind not in ('view', 'click', 'add') or not public.feature_on_for_me('bot_promoted') then return; end if;
  update public.bot_promotions set
    views = views + (kind = 'view')::int,
    clicks = clicks + (kind = 'click')::int,
    adds = adds + (kind = 'add')::int
  where id = any(pids[1:6]) and starts_at <= now() and ends_at > now() and public.bot_promo_ok(bot_id);
end $$;

-- For the Promote card on the Developer page: the bot's owner (or staff) only.
create or replace function public.bot_promo_availability(bid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if (select auth.uid()) is null or not (public.is_staff() or exists (select 1 from public.bots where id = bid and owner_id = (select auth.uid()))) then
    raise exception 'Only the bot’s owner can see this';
  end if;
  return jsonb_build_object(
    'ok', public.bot_promo_ok(bid),
    'slots', public.bot_promo_slots(),
    'taken', (select count(distinct bot_id) from public.bot_promotions where starts_at <= now() and ends_at > now()),
    'next', public.next_bot_promo_start(bid),
    'until', (select max(ends_at) from public.bot_promotions where bot_id = bid and ends_at > now())
  );
end $$;

-- Admin: promote a bot for free (testing, giveaways, partners). Queues like a paid one.
create or replace function public.admin_promote_bot(bid uuid, days int)
returns timestamptz language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if not public.bot_promo_ok(bid) then raise exception 'Only verified, listed bots can be promoted'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'bot_promo_free', bid, days || ' days');
  return public.book_bot_promotion(bid, 'admin', null, (select auth.uid()), days);
end $$;

-- Mod Center: running and queued promotions.
create or replace function public.staff_bot_promotions()
returns table(id uuid, bot_id uuid, bot_name text, owner_name text, starts_at timestamptz, ends_at timestamptz, source text,
              views int, clicks int, adds int, ok boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query
  select p.id, p.bot_id, b.name, coalesce(op.display_name, op.username), p.starts_at, p.ends_at, p.source, p.views, p.clicks, p.adds,
         public.bot_promo_ok(p.bot_id)
  from public.bot_promotions p
  join public.bots b on b.id = p.bot_id
  left join public.profiles op on op.id = b.owner_id
  where p.ends_at > now()
  order by p.starts_at, p.ends_at
  limit 100;
end $$;

-- Staff: end a promotion now (rule breaks, refunds). A queued one is ended before it starts. Logged with the reason.
create or replace function public.staff_end_bot_promotion(pid uuid, why text)
returns void language plpgsql security definer set search_path = public as $$
declare v_bot uuid;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if nullif(btrim(coalesce(why, '')), '') is null then raise exception 'Say why'; end if;
  update public.bot_promotions set starts_at = least(starts_at, now()), ends_at = now(), ended_by = (select auth.uid())
  where id = pid and ends_at > now()
  returning bot_id into v_bot;
  if v_bot is null then raise exception 'That promotion already ended'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'bot_promo_ended', v_bot, left(btrim(why), 500));
end $$;

revoke all on function public.bot_promo_ok(uuid), public.next_bot_promo_start(uuid, int), public.book_bot_promotion(uuid, text, text, uuid, int),
  public.promoted_bots(int), public.bot_promo_event(uuid[], text), public.bot_promo_availability(uuid), public.admin_promote_bot(uuid, int),
  public.staff_bot_promotions(), public.staff_end_bot_promotion(uuid, text) from public, anon, authenticated;
grant execute on function public.bot_promo_ok(uuid), public.next_bot_promo_start(uuid, int), public.book_bot_promotion(uuid, text, text, uuid, int) to service_role;
grant execute on function public.promoted_bots(int) to anon, authenticated;
grant execute on function public.bot_promo_event(uuid[], text), public.bot_promo_availability(uuid), public.admin_promote_bot(uuid, int),
  public.staff_bot_promotions(), public.staff_end_bot_promotion(uuid, text) to authenticated;

insert into public.feature_flags (key, label, description, mode, users, servers) values
  ('bot_promoted', 'Promoted bots', 'Paid Promoted spots at the top of the bot list, bought from the Developer page.', 'test',
   array['00000000-0000-4000-8000-00000000a001']::uuid[], array['00000000-0000-4000-8000-00000000b001']::uuid[])
on conflict (key) do nothing;
reset lock_timeout;
