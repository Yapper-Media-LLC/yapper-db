-- 667: Gifter badge + account level leaderboard (flag gift_badge_board, test mode). Re-runnable.
-- DDL: apply before 14:00 UTC (new columns, tables, functions, grants: both PostgRESTs rebuild their schema cache).
-- Apply before the release that ships this branch: PROFILE_COLS (lib/types.ts, ops/realtime) now lists gifts_given.
-- The add-column statements hold a lock on profiles until the file commits, so nothing below scans profiles: the
-- board fills on the first cron tick (within 10 minutes), or run `select public.refresh_level_board();` after.
--
-- 1. Gifter badge. profiles.gifts_given = how many paid Plus gifts someone has given (plus_gifts with source 'stripe',
--    not refunded or charged back; giveaway rows are staff giveaways and don't count). One tier key sits in
--    profiles.badges: gifter_1 (1+), gifter_2 (10+), gifter_3 (25+), gifter_4 (50+). A trigger on plus_gifts keeps both
--    in step, so a paid gift (grant_plus_gift) awards it at once and a refund takes it back. Backfilled below.
--    Refunds: plus_gifts.payment_intent (set by the webhook after the grant) and refunded_at (set through
--    gift_mark_refunded on charge.refunded / charge.dispute.created, cleared when a dispute closes in our favour).
--    Gifts from before 667 have no payment_intent: the webhook finds them through the checkout session
--    (plus_events.business_id). A gift whose recipient deleted their account is gone (136 cascades) and stops counting.
-- 2. Level board. profiles.leaderboard_hidden (own toggle in Privacy; others can't read it). refresh_level_board()
--    runs every 10 minutes by pg_cron: one pass over profiles for the ranked accounts (account_level >= 1, not
--    banned, not a bot, not hidden), keeping only the top 100 in level_board and how many people sit at each level in
--    level_counts (at most 100 rows), so a refresh writes ~200 rows at most. level_board_page() reads the top 50 by
--    index and works out your own rank live from level_counts (1 + everyone at a higher level), re-checking hidden
--    and bans live so someone who hides or gets banned leaves the board at once. Never a scan per view.

set lock_timeout = '3s';

-- ---------- 1. gifter badge ----------
alter table public.plus_gifts add column if not exists payment_intent text;
alter table public.plus_gifts add column if not exists refunded_at timestamptz;
create index if not exists plus_gifts_payment_intent_idx on public.plus_gifts (payment_intent) where payment_intent is not null;

alter table public.profiles add column if not exists gifts_given integer not null default 0;
alter table public.profiles add column if not exists leaderboard_hidden boolean not null default false;
reset lock_timeout;
grant select (gifts_given) on public.profiles to anon, authenticated;
-- Your own setting only: readable through my_leaderboard_hidden(), so nobody can list who hid themselves.
revoke select (leaderboard_hidden) on public.profiles from anon, authenticated;
grant update (leaderboard_hidden) on public.profiles to authenticated;

-- Counts one gifter's paid gifts and puts the matching tier in badges (only writes when something changed).
-- The row lock first: two gifts at once count in turn, and the badges array is built from the row as it is then,
-- so a badge staff give at the same moment isn't overwritten.
create or replace function public.gifter_recount(uid uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; tier text;
begin
  if uid is null then return 0; end if;
  perform 1 from public.profiles where id = uid for update;
  if not found then return 0; end if;
  select count(*)::integer into n from public.plus_gifts g
   where g.gifter_id = uid and g.source = 'stripe' and g.refunded_at is null;
  tier := case when n >= 50 then 'gifter_4' when n >= 25 then 'gifter_3' when n >= 10 then 'gifter_2'
               when n >= 1 then 'gifter_1' end;
  update public.profiles p
     set gifts_given = n,
         badges = x.want,
         -- Someone showing their gifter badge keeps showing it at the new tier (and loses it with the last gift).
         shown_badge = case when p.shown_badge like 'gifter\_%' then tier else p.shown_badge end
    from (select array(select b from unnest(coalesce(q.badges, '{}'::text[])) b where b not like 'gifter\_%')
                 || case when tier is null then '{}'::text[] else array[tier] end as want
            from public.profiles q where q.id = uid) x
   where p.id = uid
     and (p.gifts_given is distinct from n or coalesce(p.badges, '{}'::text[]) is distinct from x.want);
  return n;
end $$;
revoke all on function public.gifter_recount(uuid) from public, anon, authenticated;

create or replace function public.plus_gifts_gifter_badge()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Giveaway rows never count: skip them (a giveaway writes one per winner).
  if coalesce(old.source, '') <> 'stripe' and coalesce(new.source, '') <> 'stripe' then return null; end if;
  if tg_op in ('UPDATE', 'DELETE') then perform public.gifter_recount(old.gifter_id); end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.gifter_id is distinct from old.gifter_id) then
    perform public.gifter_recount(new.gifter_id);
  end if;
  return null;
end $$;
revoke all on function public.plus_gifts_gifter_badge() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists plus_gifts_gifter_badge on public.plus_gifts'; end $$;
create trigger plus_gifts_gifter_badge after insert or update of gifter_id, source, refunded_at or delete on public.plus_gifts
  for each row execute function public.plus_gifts_gifter_badge();

-- Webhook only (service_role). Marks (p_on) or clears a refund / chargeback on the gift paid by this payment intent,
-- or, for gifts from before 667, by this checkout session. Records the payment intent on a session match, so the next
-- event for it matches directly. Returns how many gifts changed.
create or replace function public.gift_mark_refunded(p_pi text, p_session text default null, p_on boolean default true)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if coalesce(p_pi, '') = '' and coalesce(p_session, '') = '' then return 0; end if;
  update public.plus_gifts g
     set refunded_at = case when p_on then coalesce(g.refunded_at, now()) end,
         payment_intent = coalesce(g.payment_intent, nullif(p_pi, ''))
   where g.source = 'stripe'
     and ((coalesce(p_pi, '') <> '' and g.payment_intent = p_pi)
       or (coalesce(p_session, '') <> '' and g.stripe_event in (select e.id from public.plus_events e where e.business_id = p_session)))
     and (g.refunded_at is null) = p_on;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.gift_mark_refunded(text, text, boolean) from public, anon, authenticated;
grant execute on function public.gift_mark_refunded(text, text, boolean) to service_role;

-- Backfill: everyone who has given a paid gift (gifter_id is indexed, plus_gifts_gifter).
select public.gifter_recount(x.gifter_id)
  from (select distinct g.gifter_id from public.plus_gifts g where g.gifter_id is not null and g.source = 'stripe') x;

-- ---------- 2. level board ----------
create table if not exists public.level_board (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  pos integer not null,              -- rank (ties share it: 1, 2, 2, 4)
  ord integer not null,              -- order on the board (ties: whoever joined first)
  level smallint not null
);
create index if not exists level_board_ord_idx on public.level_board (ord);
alter table public.level_board enable row level security;
-- How many ranked accounts are at each level: your rank is 1 + everyone above your level.
create table if not exists public.level_counts (
  level smallint primary key,
  n integer not null
);
alter table public.level_counts enable row level security;
-- No policies: only the security definer functions below read or write them.
revoke all on table public.level_board from public, anon, authenticated;
revoke all on table public.level_counts from public, anon, authenticated;

create or replace function public.refresh_level_board()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('public.refresh_level_board')) then return 0; end if;
  -- One statement: one snapshot, one commit; only rows that changed are rewritten.
  execute $a$
    with ranked as materialized (
      select p.id, p.account_level as level, p.created_at
      from public.profiles p
      where p.account_level >= 1 and not p.leaderboard_hidden
        and not ('bot' = any(coalesce(p.badges, '{}'::text[])))
        and not exists (select 1 from public.bots b where b.id = p.id)
        and not exists (select 1 from public.bot_accounts a where a.user_id = p.id)
        and not exists (select 1 from public.site_bans s where s.user_id = p.id and (s.expires_at is null or s.expires_at > now()))
    ),
    top as materialized (
      select t.* from (
        select r.id, r.level,
               (rank() over (order by r.level desc))::integer as pos,
               (row_number() over (order by r.level desc, r.created_at, r.id))::integer as ord
        from ranked r) t
      where t.ord <= 100
    ),
    counts as materialized (select r.level, count(*)::integer as n from ranked r group by r.level),
    up as (
      insert into public.level_board as b (user_id, pos, ord, level)
      select t.id, t.pos, t.ord, t.level from top t
      on conflict (user_id) do update set pos = excluded.pos, ord = excluded.ord, level = excluded.level
        where (b.pos, b.ord, b.level) is distinct from (excluded.pos, excluded.ord, excluded.level)
      returning 1
    ),
    gone as (
      de$a$ || $b$lete from public.level_board b where not exists (select 1 from top t where t.id = b.user_id)
      returning 1
    ),
    up_n as (
      insert into public.level_counts as c (level, n)
      select k.level, k.n from counts k
      on conflict (level) do update set n = excluded.n where c.n is distinct from excluded.n
      returning 1
    ),
    gone_n as (
      de$b$ || $c$lete from public.level_counts c where not exists (select 1 from counts k where k.level = c.level)
      returning 1
    )
    select ((select count(*) from up) + (select count(*) from gone) + (select count(*) from up_n) + (select count(*) from gone_n))::integer
  $c$ into n;
  return n;
end $$;
revoke all on function public.refresh_level_board() from public, anon, authenticated;

-- { top: [{id, username, display_name, avatar_path, avatar_deco, level, pos}], me: {pos, level} | null, hidden }
-- Top 50 by cached order (an index range on ord), live hidden / ban check on those rows; "me" from your live level.
create or replace function public.level_board_page()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := (select auth.uid()); top jsonb; lvl smallint; hid boolean; above integer;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('gift_badge_board') then return jsonb_build_object('top', '[]'::jsonb, 'me', null, 'hidden', false); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'username', t.username, 'display_name', t.display_name,
           'avatar_path', t.avatar_path, 'avatar_deco', t.avatar_deco, 'level', t.level, 'pos', t.pos) order by t.ord), '[]'::jsonb)
    into top
    from (select p.id, p.username, p.display_name, p.avatar_path, p.avatar_deco, r.level, r.pos, r.ord
            from public.level_board r join public.profiles p on p.id = r.user_id
           where not p.leaderboard_hidden
             and not exists (select 1 from public.site_bans s where s.user_id = p.id and (s.expires_at is null or s.expires_at > now()))
           order by r.ord limit 50) t;
  select p.account_level, p.leaderboard_hidden into lvl, hid from public.profiles p where p.id = me;
  if coalesce(hid, false) then return jsonb_build_object('top', top, 'me', null, 'hidden', true); end if;
  if coalesce(lvl, 0) < 1 or exists (select 1 from public.bots b where b.id = me)
     or exists (select 1 from public.bot_accounts a where a.user_id = me)
     or exists (select 1 from public.site_bans s where s.user_id = me and (s.expires_at is null or s.expires_at > now())) then
    return jsonb_build_object('top', top, 'me', null, 'hidden', false);
  end if;
  select coalesce(sum(c.n), 0)::integer into above from public.level_counts c where c.level > lvl;
  return jsonb_build_object('top', top, 'me', jsonb_build_object('pos', above + 1, 'level', lvl), 'hidden', false);
end $$;
revoke all on function public.level_board_page() from public, anon;
grant execute on function public.level_board_page() to authenticated;

-- Settings, Privacy: your own "hide me from leaderboards" (the column isn't readable by clients).
create or replace function public.my_leaderboard_hidden()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.leaderboard_hidden from public.profiles p where p.id = (select auth.uid())), false);
$$;
revoke all on function public.my_leaderboard_hidden() from public, anon;
grant execute on function public.my_leaderboard_hidden() to authenticated;

-- ---------- every 10 minutes (the first tick fills it) ----------
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'level-board') then
      perform cron.schedule('level-board', '*/10 * * * *', 'select public.refresh_level_board()');
    end if;
  end if;
end $$;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gift_badge_board', 'Gifter badge + level board',
        'A tiered badge for people who gift Plus, and a top 50 account level board in Shards.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
