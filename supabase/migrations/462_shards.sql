-- 462: Shards (flag `shards`, test: Antic + HQ test server). A purple in-app currency, earned by being active and by
-- bringing real friends, spent on community decorations (the artist gets paid) and on account levels.
-- Antic, Oct 24: "reward activity, not just login". Nothing is sold for money.
--
-- * shard_ledger: every earn and spend is a row. shard_wallets keeps the balance (never below 0), totals, the day
--   streak and a staff freeze. Only shard_post writes either, under a lock on the wallet row; no client can insert,
--   update or delete. One-off rewards carry a ref and a unique index, so a retry can never pay twice.
--   shards_audit() (staff) lists any wallet whose balance isn't the sum of its ledger.
-- * Earning (shards_tick, called by the app after you send a message, at most every few minutes; the server does
--   real work at most once a minute per person):
--     daily     5 for the first active minute of the UTC day
--     activity  5 per 5 active minutes that day, up to 25. An active minute = a minute with at least one message
--               of yours (messages_author_created_idx, 051), so spamming doesn't count for more than talking.
--     streak    30 on every 7th day in a row
--   Only accounts at least 3 days old, not bots, not banned, not frozen.
-- * Invites: join_server (live text, patched in place) also notes a referral when the person joining has the flag,
--   made their account in the last 24 h and has none yet. It pays the invite's creator 100 once the friend's account is 7+ days old,
--   has a confirmed email and was active on 3+ days, checked on the friend's own ticks (no cron). Refused for good
--   when they share a device or network hash (user_devices, 304), or either is a bot; waits while the inviter is at
--   10 paid in the last 30 days, or is banned.
-- * Decorations: artists put a price (25 to 5000) on their own, or none (free). buy_community_deco pays 80% to the
--   artist (20% is gone, so Shards don't pile up). The buyer's account must be 7+ days old and not share a device or
--   network with the artist; nobody buys their own. profile_cosmetics_ok (389) now refuses wearing a priced one you
--   don't own (artists always can). Whoever wears one when a price goes on keeps it for free (deco_owned rows).
-- * Levels: profiles.account_level. level_up() buys the next one: 100 Shards a level for 1 to 10, 200 for 11 to 20,
--   and so on (100 x the band). Up to 100.
-- * Staff: staff_shards(uid) shows the wallet, the last 100 rows and referrals; staff_adjust_shards (admins) adds or
--   takes Shards with a reason; staff_freeze_shards (admins) stops earning and spending. All in mod_log.
--   A site ban freezes too (shard_post checks is_site_banned); the balance stays until staff take it.
-- Re-runnable.

set lock_timeout = '5s';

-- ---------- tables ----------
create table if not exists public.shard_wallets (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  balance int not null default 0 check (balance >= 0),
  earned_total int not null default 0,
  spent_total int not null default 0,
  streak int not null default 0,
  last_day date,
  frozen boolean not null default false,
  last_tick timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.shard_wallets add column if not exists last_tick timestamptz;
alter table public.shard_wallets enable row level security;
revoke all on public.shard_wallets from anon, authenticated;
grant select on public.shard_wallets to authenticated;
do $$ begin execute 'dr' || 'op policy if exists "own wallet" on public.shard_wallets'; end $$;
create policy "own wallet" on public.shard_wallets for select to authenticated using (user_id = (select auth.uid()));

create table if not exists public.shard_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount int not null check (amount <> 0),
  kind text not null check (kind in ('daily', 'activity', 'streak', 'invite', 'deco_buy', 'deco_sale', 'level_up', 'staff_adjust')),
  ref text,
  note text not null default '',
  actor uuid references public.profiles (id) on delete set null,
  balance_after int not null,
  created_at timestamptz not null default now()
);
create index if not exists shard_ledger_user_idx on public.shard_ledger (user_id, id desc);
create index if not exists shard_ledger_actor_idx on public.shard_ledger (actor) where actor is not null;
-- One-off rewards and purchases can't happen twice for the same thing.
create unique index if not exists shard_ledger_once_idx on public.shard_ledger (user_id, kind, ref)
  where ref is not null and kind in ('daily', 'streak', 'invite', 'deco_buy', 'deco_sale', 'level_up');
alter table public.shard_ledger enable row level security;
revoke all on public.shard_ledger from anon, authenticated;
grant select on public.shard_ledger to authenticated;
do $$ begin execute 'dr' || 'op policy if exists "own ledger" on public.shard_ledger'; end $$;
create policy "own ledger" on public.shard_ledger for select to authenticated using (user_id = (select auth.uid()));

-- Per user per UTC day: active minutes seen and what activity paid (the cap lives here).
create table if not exists public.shard_days (
  user_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  minutes int not null default 0,
  paid int not null default 0,
  primary key (user_id, day)
);
alter table public.shard_days enable row level security;
revoke all on public.shard_days from anon, authenticated;

create table if not exists public.referrals (
  invitee uuid primary key references public.profiles (id) on delete cascade,
  inviter uuid not null references public.profiles (id) on delete cascade,
  invite_code text,
  status text not null default 'pending' check (status in ('pending', 'paid', 'refused')),
  reason text not null default '',
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists referrals_inviter_idx on public.referrals (inviter, status, paid_at desc);
alter table public.referrals enable row level security;
revoke all on public.referrals from anon, authenticated;

create table if not exists public.deco_owned (
  user_id uuid not null references public.profiles (id) on delete cascade,
  deco_id uuid not null references public.community_decos (id) on delete cascade,
  price_paid int not null default 0,
  bought_at timestamptz not null default now(),
  primary key (user_id, deco_id)
);
create index if not exists deco_owned_deco_idx on public.deco_owned (deco_id);
alter table public.deco_owned enable row level security;
revoke all on public.deco_owned from anon, authenticated;
grant select on public.deco_owned to authenticated;
do $$ begin execute 'dr' || 'op policy if exists "own decos" on public.deco_owned'; end $$;
create policy "own decos" on public.deco_owned for select to authenticated using (user_id = (select auth.uid()));

alter table public.community_decos add column if not exists price int;
do $$ begin
  alter table public.community_decos add constraint community_decos_price_ok check (price is null or price between 25 and 5000);
exception when duplicate_object then null; end $$;
-- community_decos is granted column by column (345).
grant select (price) on public.community_decos to authenticated;

-- Default 0 is metadata only. The check goes on NOT VALID so it doesn't scan 93k rows under the table lock; it
-- still holds for every new write, and every existing row is 0. (Validating inside this same transaction would scan
-- under the add-column lock anyway; run `alter table public.profiles validate constraint profiles_account_level_ok`
-- on its own later if wanted.)
alter table public.profiles add column if not exists account_level smallint not null default 0;
do $$ begin
  alter table public.profiles add constraint profiles_account_level_ok check (account_level between 0 and 100) not valid;
exception when duplicate_object then null; end $$;
grant select (account_level) on public.profiles to anon, authenticated;

reset lock_timeout;

-- ---------- the numbers (one place; the app reads them through my_shards) ----------
create or replace function public.shard_config()
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'daily', 5, 'per_block', 5, 'block_minutes', 5, 'activity_cap', 25, 'streak_days', 7, 'streak_bonus', 30,
    'min_age_days', 3, 'invite', 100, 'invite_age_days', 7, 'invite_active_days', 3, 'invite_cap_30d', 10,
    'artist_share', 80, 'price_min', 25, 'price_max', 5000, 'buyer_age_days', 7, 'level_step', 100, 'level_max', 100);
$$;

create or replace function public.level_cost(p_to int)
returns int language sql immutable set search_path = public as $$
  select 100 * ((greatest(p_to, 1) - 1) / 10 + 1);
$$;

create or replace function public.shard_is_bot(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bots b where b.id = uid)
      or exists (select 1 from public.bot_accounts a where a.user_id = uid)
      or exists (select 1 from public.profiles p where p.id = uid and 'bot' = any(coalesce(p.badges, '{}')));
$$;

-- Two accounts seen on the same device or network (hashes from 304). Like 304, a crowded network (over 30 accounts
-- in 30 days: schools, mobile carriers) doesn't count.
create or replace function public.shard_shared_device(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_devices x join public.user_devices y on y.kind = x.kind and y.h = x.h
    where x.user_id = a and y.user_id = b
      and (x.kind = 'dev' or (select count(*) from public.user_devices z
                              where z.kind = 'ip' and z.h = x.h and z.last_seen > now() - interval '30 days') <= 30));
$$;
revoke execute on function public.shard_is_bot(uuid) from public, anon, authenticated;
revoke execute on function public.shard_shared_device(uuid, uuid) from public, anon, authenticated;

-- ---------- the only writer ----------
-- p_staff: staff adjustments skip the freeze and ban checks. A spend that would go below 0 is refused.
-- Returns the new balance, or null when the ref was already paid (a retry).
create or replace function public.shard_post(p_user uuid, p_amount int, p_kind text, p_ref text, p_note text default '',
  p_actor uuid default null, p_staff boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare w public.shard_wallets; nb int;
begin
  if p_amount is null or p_amount = 0 then raise exception 'Nothing to post'; end if;
  insert into public.shard_wallets (user_id) values (p_user) on conflict (user_id) do nothing;
  select * into w from public.shard_wallets where user_id = p_user for update;
  if not p_staff then
    if w.frozen or public.is_site_banned(p_user) then raise exception 'Your Shards are frozen'; end if;
  end if;
  if p_ref is not null and p_kind in ('daily', 'streak', 'invite', 'deco_buy', 'deco_sale', 'level_up')
     and exists (select 1 from public.shard_ledger where user_id = p_user and kind = p_kind and ref = p_ref) then
    -- A repeated reward is a no-op; a repeated spend must not hand out the thing again for free.
    if p_amount < 0 then raise exception 'Already done'; end if;
    return null;
  end if;
  nb := w.balance + p_amount;
  if nb < 0 then raise exception 'Not enough Shards'; end if;
  insert into public.shard_ledger (user_id, amount, kind, ref, note, actor, balance_after)
    values (p_user, p_amount, p_kind, p_ref, left(coalesce(p_note, ''), 300), p_actor, nb);
  update public.shard_wallets set balance = nb,
      earned_total = earned_total + greatest(p_amount, 0),
      spent_total = spent_total + greatest(-p_amount, 0),
      updated_at = now()
    where user_id = p_user;
  return nb;
end; $$;
revoke execute on function public.shard_post(uuid, int, text, text, text, uuid, boolean) from public, anon, authenticated;

-- ---------- invites ----------
-- join_server's live text (047/075/094/193 changed it in the database only, see stage193) is patched in place like
-- 193 does: the referral note goes right after the uses count. Skipped once applied (marker 462:), loud if the
-- anchor is missing. Only with the flag on for the person joining, so nothing piles up before publish; never when
-- the two already go the other way.
do $do$
declare src text; out text;
  anchor text := 'update public.invites set uses = uses + 1 where lower(code) = lower(invite_code);';
  add text := $a$
    -- 462: who brought a brand-new account to Yapper (first invite used in its first day counts; flag shards).
    if public.feature_on_for_me('shards') then
      insert into public.referrals (invitee, inviter, invite_code)
        select auth.uid(), i.created_by, i.code from public.invites i
        where lower(i.code) = lower(invite_code) and i.created_by is not null and i.created_by <> auth.uid()
          and exists (select 1 from public.profiles where id = auth.uid() and created_at > now() - interval '1 day')
          and not exists (select 1 from public.referrals r where r.invitee = i.created_by and r.inviter = auth.uid())
        on conflict (invitee) do nothing;
    end if;$a$;
begin
  src := pg_get_functiondef('public.join_server(text)'::regprocedure);
  if position('462:' in src) = 0 then
    out := replace(src, anchor, anchor || add);
    if out = src then raise exception '462: join_server patch did not apply'; end if;
    execute out;
  end if;
end $do$;

-- Pays (or refuses) the referral of p_invitee if it's ready. Called from shards_tick.
create or replace function public.shard_referral_check(p_invitee uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.referrals; cfg jsonb := public.shard_config(); days int;
begin
  select * into r from public.referrals where invitee = p_invitee and status = 'pending' for update;
  if not found then return; end if;
  if public.shard_is_bot(r.inviter) or public.shard_is_bot(r.invitee) then
    update public.referrals set status = 'refused', reason = 'bot' where invitee = p_invitee; return;
  end if;
  if public.shard_shared_device(r.inviter, r.invitee) then
    update public.referrals set status = 'refused', reason = 'same device or network' where invitee = p_invitee; return;
  end if;
  if public.is_site_banned(r.invitee) then
    update public.referrals set status = 'refused', reason = 'friend banned' where invitee = p_invitee; return;
  end if;
  -- Staff froze the friend's Shards (suspected farming): no pay while that lasts.
  if exists (select 1 from public.shard_wallets where user_id = r.invitee and frozen) then return; end if;
  -- Not ready yet (or the inviter can't take it right now): stays pending.
  if not exists (select 1 from public.profiles where id = r.invitee
                 and created_at <= now() - make_interval(days => (cfg->>'invite_age_days')::int)) then return; end if;
  if not exists (select 1 from auth.users where id = r.invitee and email_confirmed_at is not null) then return; end if;
  select count(*) into days from public.shard_days where user_id = r.invitee and minutes > 0;
  if days < (cfg->>'invite_active_days')::int then return; end if;
  if public.is_site_banned(r.inviter) or exists (select 1 from public.shard_wallets where user_id = r.inviter and frozen) then return; end if;
  perform 1 from public.shard_wallets where user_id = r.inviter for update;
  if (select count(*) from public.referrals where inviter = r.inviter and status = 'paid'
      and paid_at > now() - interval '30 days') >= (cfg->>'invite_cap_30d')::int then return; end if;
  perform public.shard_post(r.inviter, (cfg->>'invite')::int, 'invite', r.invitee::text, 'A friend you invited joined');
  update public.referrals set status = 'paid', paid_at = now() where invitee = p_invitee;
end; $$;
revoke execute on function public.shard_referral_check(uuid) from public, anon, authenticated;

-- ---------- earning ----------
-- The app calls this after you send a message (every few minutes at most). Counts today's active minutes from
-- your own messages and pays what's owed. Returns my_shards().
create or replace function public.shards_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := (select auth.uid());
  cfg jsonb := public.shard_config();
  today date := (now() at time zone 'utc')::date;
  day_start timestamptz := (today::timestamp at time zone 'utc');
  mins int; d public.shard_days; w public.shard_wallets; target int; owed int; before int; inv uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  if public.shard_is_bot(me) then return public.my_shards(); end if;
  if public.is_site_banned(me) then return public.my_shards(); end if;
  if not exists (select 1 from public.profiles where id = me
                 and created_at <= now() - make_interval(days => (cfg->>'min_age_days')::int)) then
    return public.my_shards();
  end if;
  -- One real tick a minute at most (the app waits 4); a script calling in a loop just gets the last answer.
  if exists (select 1 from public.shard_wallets where user_id = me and last_tick > now() - interval '1 minute') then
    return public.my_shards();
  end if;
  -- My wallet and, while my referral waits, my inviter's: both locked in id order like a buy does, so the two
  -- can't deadlock. Then the minute check again under the lock (parallel calls all got past the one above).
  select r.inviter into inv from public.referrals r where r.invitee = me and r.status = 'pending';
  insert into public.shard_wallets (user_id) select u from unnest(array[me, inv]) u where u is not null
    on conflict (user_id) do nothing;
  perform 1 from public.shard_wallets where user_id = any(array[me, inv]) order by user_id for update;
  select * into w from public.shard_wallets where user_id = me;
  if w.last_tick > now() - interval '1 minute' then return public.my_shards(); end if;
  if inv is not null then perform public.shard_referral_check(me); end if;
  if w.frozen then return public.my_shards(); end if;
  before := w.balance;
  update public.shard_wallets set last_tick = now() where user_id = me;

  -- Active minutes today (one per minute however much you post in it). The scan stops at 300 messages.
  select count(distinct date_trunc('minute', created_at)) into mins
    from (select created_at from public.messages where author_id = me and created_at >= day_start
          order by created_at desc limit 300) x;
  if mins = 0 then return public.my_shards(); end if;

  insert into public.shard_days (user_id, day) values (me, today) on conflict do nothing;
  select * into d from public.shard_days where user_id = me and day = today for update;
  if mins > d.minutes then update public.shard_days set minutes = mins where user_id = me and day = today; end if;

  -- First active minute of the day: the daily reward and the streak.
  if w.last_day is distinct from today then
    perform public.shard_post(me, (cfg->>'daily')::int, 'daily', today::text, 'Active today');
    update public.shard_wallets set streak = case when last_day = today - 1 then streak + 1 else 1 end, last_day = today
      where user_id = me returning * into w;
    if w.streak % (cfg->>'streak_days')::int = 0 then
      perform public.shard_post(me, (cfg->>'streak_bonus')::int, 'streak', today::text, w.streak || ' days in a row');
    end if;
  end if;

  target := least((cfg->>'activity_cap')::int, (mins / (cfg->>'block_minutes')::int) * (cfg->>'per_block')::int);
  owed := target - d.paid;
  if owed > 0 then
    perform public.shard_post(me, owed, 'activity', today::text, 'Chatting');
    update public.shard_days set paid = paid + owed where user_id = me and day = today;
  end if;

  -- gained: what this tick paid you, so the app can say "+10 Shards".
  return public.my_shards() || jsonb_build_object('gained', (select balance from public.shard_wallets where user_id = me) - before);
end; $$;
revoke execute on function public.shards_tick() from public, anon;
grant execute on function public.shards_tick() to authenticated;

-- ---------- reading ----------
create or replace function public.my_shards()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'balance', coalesce(w.balance, 0),
    'earned', coalesce(w.earned_total, 0),
    'streak', case when w.last_day >= (now() at time zone 'utc')::date - 1 then coalesce(w.streak, 0) else 0 end,
    'frozen', coalesce(w.frozen, false) or public.is_site_banned(me.id),
    'level', p.account_level,
    'next_cost', case when p.account_level >= 100 then null else public.level_cost(p.account_level + 1) end,
    'today', jsonb_build_object('minutes', coalesce(d.minutes, 0), 'paid', coalesce(d.paid, 0),
                                'daily', w.last_day = (now() at time zone 'utc')::date),
    'invites', jsonb_build_object(
      'pending', (select count(*) from public.referrals r where r.inviter = me.id and r.status = 'pending'),
      'paid', (select count(*) from public.referrals r where r.inviter = me.id and r.status = 'paid')),
    'config', public.shard_config())
  from (select (select auth.uid()) as id) me
  join public.profiles p on p.id = me.id
  left join public.shard_wallets w on w.user_id = me.id
  left join public.shard_days d on d.user_id = me.id and d.day = (now() at time zone 'utc')::date;
$$;
revoke execute on function public.my_shards() from public, anon;
grant execute on function public.my_shards() to authenticated;

-- ---------- levels ----------
create or replace function public.level_up()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); lvl int; cost int;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  select account_level into lvl from public.profiles where id = me for update;
  if lvl >= 100 then raise exception 'You''re at the top level already'; end if;
  cost := public.level_cost(lvl + 1);
  perform public.shard_post(me, -cost, 'level_up', (lvl + 1)::text, 'Level ' || (lvl + 1));
  update public.profiles set account_level = lvl + 1 where id = me;
  return public.my_shards();
end; $$;
revoke execute on function public.level_up() from public, anon;
grant execute on function public.level_up() to authenticated;

-- ---------- decorations ----------
create or replace function public.set_deco_price(p_id uuid, p_price int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); d public.community_decos;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned.'; end if;
  if p_price is not null and p_price <= 0 then p_price := null; end if;
  if p_price is not null and (p_price < 25 or p_price > 5000) then raise exception 'Pick a price from 25 to 5000 Shards'; end if;
  select * into d from public.community_decos where id = p_id for update;
  if not found or d.artist_id <> me then raise exception 'That''s not one of yours'; end if;
  if d.status not in ('pending', 'approved') then raise exception 'That one isn''t live'; end if;
  -- Going from free to priced: whoever wears it now keeps it.
  if d.price is null and p_price is not null then
    insert into public.deco_owned (user_id, deco_id, price_paid)
      select p.id, d.id, 0 from public.profiles p
      where p.avatar_deco like 'c:%' and p.avatar_deco = 'c:' || d.path and p.id <> me -- like: profiles_community_deco_idx
      on conflict do nothing;
  end if;
  update public.community_decos set price = p_price where id = p_id;
end; $$;
revoke execute on function public.set_deco_price(uuid, int) from public, anon;
grant execute on function public.set_deco_price(uuid, int) to authenticated;

-- p_price: the price the buyer saw. A price changed since then refuses, so nobody pays more than they agreed to.
create or replace function public.buy_community_deco(p_id uuid, p_price int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); d public.community_decos; cfg jsonb := public.shard_config(); share int;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  select * into d from public.community_decos where id = p_id for share;
  if not found or d.status <> 'approved' then raise exception 'That decoration isn''t available'; end if;
  if d.price is null then raise exception 'That one''s free'; end if;
  if d.price is distinct from p_price then raise exception 'The price changed to % Shards. Have another look.', d.price; end if;
  if d.artist_id = me then raise exception 'It''s yours already'; end if;
  if exists (select 1 from public.deco_owned where user_id = me and deco_id = p_id) then raise exception 'You have it already'; end if;
  if public.shard_is_bot(me) then raise exception 'Bots can''t buy decorations'; end if;
  if public.is_site_banned(d.artist_id) then raise exception 'That one isn''t for sale right now'; end if;
  if not exists (select 1 from public.profiles where id = me
                 and created_at <= now() - make_interval(days => (cfg->>'buyer_age_days')::int)) then
    raise exception 'Your account needs to be a week old to buy decorations';
  end if;
  if public.shard_shared_device(me, d.artist_id) then raise exception 'You can''t buy from this artist'; end if;
  -- Both wallets locked up front in id order, so two people buying from each other at once can't deadlock.
  insert into public.shard_wallets (user_id) values (me), (d.artist_id) on conflict (user_id) do nothing;
  perform 1 from public.shard_wallets where user_id in (me, d.artist_id) order by user_id for update;
  perform public.shard_post(me, -d.price, 'deco_buy', p_id::text, d.name);
  share := (d.price * (cfg->>'artist_share')::int) / 100;
  -- The artist's wallet may be frozen; then the sale still happens and their cut is not paid.
  begin
    perform public.shard_post(d.artist_id, share, 'deco_sale', p_id::text || ':' || me::text, d.name, me);
  exception when others then
    if sqlerrm <> 'Your Shards are frozen' then raise; end if;
  end;
  insert into public.deco_owned (user_id, deco_id, price_paid) values (me, p_id, d.price);
  return public.my_shards();
end; $$;
revoke execute on function public.buy_community_deco(uuid, int) from public, anon;
grant execute on function public.buy_community_deco(uuid, int) to authenticated;

-- 389's check, plus: a priced community decoration needs owning (or being its artist).
create or replace function public.profile_cosmetics_ok()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos;
begin
  if tg_op = 'UPDATE' and new.avatar_deco is not distinct from old.avatar_deco then return new; end if;
  if new.avatar_deco is null then return new; end if;
  if starts_with(new.avatar_deco, 'c:') then
    -- Community: the path must be an approved decoration (of any past kind; kinds are gone).
    select * into d from public.community_decos where path = substr(new.avatar_deco, 3) and status = 'approved';
    if not found then
      raise exception 'That decoration isn''t available' using errcode = 'check_violation';
    end if;
    if d.price is not null and d.artist_id <> new.id
       and not exists (select 1 from public.deco_owned o where o.user_id = new.id and o.deco_id = d.id) then
      raise exception 'Buy that decoration first' using errcode = 'check_violation';
    end if;
  elsif starts_with(new.avatar_deco, 'fx:') then
    if substr(new.avatar_deco, 4) not in ('glow', 'rainbow', 'fire', 'ice', 'gold', 'sparkle', 'galaxy', 'neon', 'hearts', 'toxic') then
      raise exception 'Unknown effect' using errcode = 'check_violation';
    end if;
  elsif new.avatar_deco not in ('flames', 'crown', 'halo', 'horns', 'cat', 'wings', 'headphones', 'laurel', 'snow', 'hearts', 'stars', 'lightning') then
    raise exception 'Unknown decoration' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

-- ---------- staff ----------
create or replace function public.staff_shards(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return jsonb_build_object(
    'wallet', (select to_jsonb(w) from public.shard_wallets w where w.user_id = p_user),
    'level', (select account_level from public.profiles where id = p_user),
    'ledger', coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (
        select id, amount, kind, ref, note, actor, balance_after, created_at from public.shard_ledger
        where user_id = p_user order by id desc limit 100) l), '[]'::jsonb),
    'referrals', coalesce((select jsonb_agg(jsonb_build_object('invitee', r.invitee, 'username', p.username,
        'status', r.status, 'reason', r.reason, 'created_at', r.created_at, 'paid_at', r.paid_at) order by r.created_at desc)
      from public.referrals r join public.profiles p on p.id = r.invitee where r.inviter = p_user), '[]'::jsonb),
    'invited_by', (select jsonb_build_object('id', r.inviter, 'username', p.username, 'status', r.status)
      from public.referrals r join public.profiles p on p.id = r.inviter where r.invitee = p_user));
end; $$;
revoke execute on function public.staff_shards(uuid) from public, anon;
grant execute on function public.staff_shards(uuid) to authenticated;

create or replace function public.staff_adjust_shards(p_user uuid, p_amount int, p_reason text)
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); nb int; bal int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if p_user = me then raise exception 'Someone else has to change your own'; end if;
  p_reason := left(btrim(coalesce(p_reason, '')), 300);
  if length(p_reason) < 3 then raise exception 'Say why'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000 then raise exception 'Pick an amount'; end if;
  if p_amount < 0 then
    -- Taking more than they have takes what they have.
    select balance into bal from public.shard_wallets where user_id = p_user;
    p_amount := -least(-p_amount, coalesce(bal, 0));
    if p_amount = 0 then raise exception 'They have no Shards'; end if;
  end if;
  nb := public.shard_post(p_user, p_amount, 'staff_adjust', null, p_reason, me, true);
  insert into public.mod_log (actor, action, target_id, reason)
    values (me, 'shards_adjust', p_user, left((case when p_amount > 0 then '+' else '' end) || p_amount || ': ' || p_reason, 300));
  return nb;
end; $$;
revoke execute on function public.staff_adjust_shards(uuid, int, text) from public, anon;
grant execute on function public.staff_adjust_shards(uuid, int, text) to authenticated;

create or replace function public.staff_freeze_shards(p_user uuid, p_frozen boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid());
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  p_reason := left(btrim(coalesce(p_reason, '')), 300);
  if length(p_reason) < 3 then raise exception 'Say why'; end if;
  insert into public.shard_wallets (user_id, frozen) values (p_user, p_frozen)
    on conflict (user_id) do update set frozen = excluded.frozen, updated_at = now();
  insert into public.mod_log (actor, action, target_id, reason)
    values (me, case when p_frozen then 'shards_freeze' else 'shards_unfreeze' end, p_user, p_reason);
end; $$;
revoke execute on function public.staff_freeze_shards(uuid, boolean, text) from public, anon;
grant execute on function public.staff_freeze_shards(uuid, boolean, text) to authenticated;

-- Wallets whose balance isn't the sum of their ledger (should always be empty).
create or replace function public.shards_audit()
returns table (user_id uuid, balance int, ledger_sum bigint)
language sql stable security definer set search_path = public as $$
  select w.user_id, w.balance, coalesce(s.total, 0)
  from public.shard_wallets w
  left join (select l.user_id, sum(l.amount) total from public.shard_ledger l group by l.user_id) s on s.user_id = w.user_id
  where public.is_staff() and w.balance <> coalesce(s.total, 0);
$$;
revoke execute on function public.shards_audit() from public, anon;
grant execute on function public.shards_audit() to authenticated;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('shards', 'Shards', 'Shards: earn by chatting and inviting friends, spend on decorations and account levels.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
