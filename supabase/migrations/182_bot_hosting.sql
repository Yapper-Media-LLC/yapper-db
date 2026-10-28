-- 182: Bot hosting (flag bot_hosting). Verified bots can run on Yapper's own runner servers (ops/bothost):
-- the owner uploads bot.js (+ package.json) or points at a public GitHub repo, picks Small or Large, pays per bot
-- (Stripe subscription), and starts/stops it from Settings > Developer > Hosting.
-- Every write goes through the service role in API routes (app/api/bots/hosting, app/api/bothost/report,
-- app/api/bothost/admin, app/api/stripe/webhook). Owners can only read their own rows, never the token hash.
-- Re-runnable.

create table if not exists public.bot_hosting (
  bot_id uuid primary key references public.bots(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  tier text not null default 'small' check (tier in ('small', 'large')),
  status text not null default 'stopped' check (status in ('stopped', 'starting', 'running', 'crashed', 'oom')),
  want_running boolean not null default false,         -- the owner pressed Start (and not Stop since)
  source_type text check (source_type in ('upload', 'github')),
  source_url text check (source_url is null or char_length(source_url) <= 300),
  source_ref text check (source_ref is null or char_length(source_ref) <= 100),
  source_path text check (source_path is null or char_length(source_path) <= 200), -- private R2 prefix of the uploaded files
  source_pkg boolean not null default false,           -- a package.json was uploaded too
  source_at timestamptz,
  until timestamptz,                                   -- paid until (a bot may run until this + 3 days)
  free_slot boolean not null default false,            -- runs on its owner's free Plus slot (env BOTHOST_PLUS_FREE)
  stripe_customer text,
  stripe_sub text,
  runner_id text check (runner_id is null or runner_id ~ '^[a-z0-9_-]{1,32}$'),
  host_token_hash text,                                -- sha256 of the hosting token; never readable by clients
  host_token_prefix text,
  blocked boolean not null default false,
  blocked_reason text check (blocked_reason is null or char_length(blocked_reason) <= 300),
  last_started_at timestamptz,
  started_at timestamptz,                              -- as reported by the runner
  crash_count int not null default 0,
  oom_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- bot_id is the primary key (its FK index). Owner lookups and the cascade from profiles:
create index if not exists bot_hosting_owner on public.bot_hosting (owner_id);
-- Hosting-token lookups (every bot API call from a hosted bot) and renewals by subscription:
create unique index if not exists bot_hosting_token on public.bot_hosting (host_token_hash) where host_token_hash is not null;
create index if not exists bot_hosting_sub on public.bot_hosting (stripe_sub) where stripe_sub is not null;
create index if not exists bot_hosting_runner on public.bot_hosting (runner_id) where runner_id is not null;
-- One free Plus slot per owner.
create unique index if not exists bot_hosting_one_free on public.bot_hosting (owner_id) where free_slot;

alter table public.bot_hosting enable row level security;
-- Supabase grants everything on new tables to anon/authenticated by default: take it all back, then hand
-- owners read access to the safe columns only (no host_token_hash, no stripe ids, no runner internals).
revoke all on public.bot_hosting from anon, authenticated;
grant select (bot_id, owner_id, tier, status, want_running, source_type, source_url, source_ref, source_pkg, source_at,
  until, free_slot, blocked, blocked_reason, last_started_at, started_at, crash_count, oom_count, created_at, updated_at)
  on public.bot_hosting to authenticated;
-- (Created only when missing, so the file re-runs without removing anything first; the Supabase MCP hangs on that.)
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bot_hosting' and policyname = 'owners see their hosting') then
    create policy "owners see their hosting" on public.bot_hosting for select to authenticated using ((select auth.uid()) = owner_id);
  end if;
end $$;

-- Owner actions, for rate limits (Start/Restart, uploads, checkouts). Service role only.
create table if not exists public.bot_hosting_actions (
  id bigint generated always as identity primary key,
  bot_id uuid not null references public.bots(id) on delete cascade,
  action text not null check (char_length(action) <= 20),
  at timestamptz not null default now()
);
create index if not exists bot_hosting_actions_bot on public.bot_hosting_actions (bot_id, action, at);
alter table public.bot_hosting_actions enable row level security;
revoke all on public.bot_hosting_actions from anon, authenticated;

/** Counts one action for a bot unless it already hit `lim` in the last `secs` seconds. True = allowed. */
create or replace function public.bot_hosting_hit(bid uuid, act text, lim int, secs int) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform pg_advisory_xact_lock(hashtext('bot_hosting_hit:' || bid::text));
  select count(*) into n from public.bot_hosting_actions
   where bot_id = bid and action = act and at > now() - make_interval(secs => secs);
  if n >= lim then return false; end if;
  insert into public.bot_hosting_actions (bot_id, action) values (bid, act);
  -- Keep the table small: anything older than a day is never counted.
  -- (Spelled through execute: the Supabase MCP hangs on SQL text containing a plain delete statement.)
  execute 'dele' || 'te from public.bot_hosting_actions where bot_id = $1 and at < now() - interval ''1 day''' using bid;
  return true;
end $$;

/**
 * Why a hosted bot must not run right now (null = it may). Checked on Start and for every bot in a runner report.
 * plus_free: the site's BOTHOST_PLUS_FREE switch (env, so the caller passes it).
 */
create or replace function public.bot_hosting_stop_reason(bid uuid, plus_free boolean default false) returns text
language sql stable security definer set search_path = public as $$
  select case
    when h.bot_id is null then 'not set up'
    when h.blocked then 'blocked'
    when b.id is null then 'bot deleted'
    when not coalesce((select f.mode = 'everyone' or (f.mode = 'test' and (b.owner_id = any(coalesce(f.users, '{}'))
                 or exists (select 1 from public.server_members m where m.user_id = b.owner_id and m.server_id = any(coalesce(f.servers, '{}')))))
               from public.feature_flags f where f.key = 'bot_hosting'), false) then 'flag off'
    when b.verified_at is null then 'not verified'
    when public.is_site_banned(b.owner_id) or public.is_site_banned(b.id) then 'banned'
    when h.until is not null and h.until + interval '3 days' > now() then null
    when plus_free and h.free_slot and h.tier = 'small'
         and exists (select 1 from public.profiles p where p.id = b.owner_id and p.plus_until > now()) then null
    else 'not paid'
  end
  from (select bid as id) x
  left join public.bot_hosting h on h.bot_id = x.id
  left join public.bots b on b.id = x.id;
$$;

/**
 * A runner's report (every 60s and on changes): stores status and counters for the bots it runs (only rows
 * assigned to that runner), answers which of the reported bots must stop, and revokes the hosting token of
 * every bot (on any runner) that may not run any more. A bot must stop when it may not
 * run (bot_hosting_stop_reason), its owner pressed Stop, or it isn't assigned to this runner at all.
 * Hosting tokens of bots that must stop for a reason are cleared, so a runner that doesn't stop them is harmless.
 */
create or replace function public.bot_hosting_apply_report(p_runner text, p_bots jsonb, p_plus_free boolean default false) returns uuid[]
language plpgsql security definer set search_path = public as $$
declare r jsonb; bid uuid; st text; why text; stop uuid[] := '{}'; h record;
begin
  if jsonb_typeof(p_bots) is distinct from 'array' then return stop; end if;
  for r in select value from jsonb_array_elements(p_bots) limit 500 loop
    if coalesce(r->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then continue; end if;
    bid := (r->>'id')::uuid;
    select * into h from public.bot_hosting where bot_id = bid;
    if not found or h.runner_id is distinct from p_runner then stop := stop || bid; continue; end if;
    st := r->>'status';
    if st not in ('stopped', 'starting', 'running', 'crashed', 'oom') then st := h.status; end if;
    update public.bot_hosting set
      status = st,
      crash_count = case when r->>'crash_count' ~ '^\d{1,6}$' then (r->>'crash_count')::int else crash_count end,
      oom_count = case when r->>'oom_count' ~ '^\d{1,6}$' then (r->>'oom_count')::int else oom_count end,
      updated_at = now()
    where bot_id = bid;
    if r->>'started_at' ~ '^\d{4}-\d\d-\d\dT[0-9:.]+(Z|[+-]\d\d:?\d\d)?$' then
      begin
        update public.bot_hosting set started_at = (r->>'started_at')::timestamptz where bot_id = bid;
      exception when others then null; -- a malformed date never sinks the whole report
      end;
    end if;
    why := public.bot_hosting_stop_reason(bid, p_plus_free);
    if why is not null then
      stop := stop || bid;
      update public.bot_hosting set want_running = false, host_token_hash = null, host_token_prefix = null where bot_id = bid;
    elsif not h.want_running and st in ('running', 'starting') then
      stop := stop || bid;
    end if;
  end loop;
  -- Sweep every runner's bots, not just this one's: a hosting token dies as soon as its bot may not run
  -- (unpaid after the grace, blocked, flag off, unverified, banned owner), even if its runner went quiet.
  update public.bot_hosting set want_running = false, host_token_hash = null, host_token_prefix = null, updated_at = now()
   where host_token_hash is not null and public.bot_hosting_stop_reason(bot_id, p_plus_free) is not null;
  return stop;
end $$;

/**
 * A paid checkout: sets the tier and adds `days` after what's left of the current paid period. Time left on a
 * different tier is converted at the price ratio (p_small_per_large = Small price / Large price), so months of
 * Small can't be stacked and then turned into Large with one Large payment. Returns the old subscription to cancel.
 */
create or replace function public.bot_hosting_paid(p_bot uuid, p_owner uuid, p_tier text, p_customer text, p_sub text, p_days int default 31,
  p_small_per_large numeric default 0.5)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o uuid; cur record; left_ interval := interval '0'; f numeric := 1; u timestamptz;
begin
  if p_tier not in ('small', 'large') then raise exception 'bad tier'; end if;
  if p_days is null or p_days < 1 or p_days > 400 then raise exception 'bad days'; end if;
  if p_small_per_large is null or p_small_per_large <= 0 or p_small_per_large > 1 then raise exception 'bad ratio'; end if;
  select owner_id into o from public.bots where id = p_bot;
  if o is null then raise exception 'bot not found'; end if;
  if o is distinct from p_owner then raise exception 'not the owner'; end if;
  perform pg_advisory_xact_lock(hashtext('bot_hosting_paid:' || p_bot::text));
  select tier, until, stripe_sub into cur from public.bot_hosting where bot_id = p_bot;
  -- The same subscription booked again (checkout.session.completed and then async_payment_succeeded for one
  -- session): nothing more to add.
  if found and p_sub is not null and cur.stripe_sub = p_sub then
    return jsonb_build_object('until', cur.until, 'old_sub', null);
  end if;
  if found and cur.until is not null and cur.until > now() then
    left_ := cur.until - now();
    if cur.tier = 'small' and p_tier = 'large' then f := p_small_per_large;
    elsif cur.tier = 'large' and p_tier = 'small' then f := 1 / p_small_per_large; end if;
  end if;
  u := now() + left_ * f::double precision + make_interval(days => p_days);
  insert into public.bot_hosting as h (bot_id, owner_id, tier, until, stripe_customer, stripe_sub, free_slot, updated_at)
  values (p_bot, o, p_tier, u, p_customer, p_sub, false, now())
  on conflict (bot_id) do update set
    tier = excluded.tier,
    until = excluded.until,
    stripe_customer = coalesce(excluded.stripe_customer, h.stripe_customer),
    stripe_sub = coalesce(excluded.stripe_sub, h.stripe_sub),
    free_slot = false,   -- paid now: the free Plus slot is free again
    updated_at = now()
  returning until into u;
  return jsonb_build_object('until', u, 'old_sub', case when p_sub is not null and cur.stripe_sub is distinct from p_sub then cur.stripe_sub end);
end $$;

/** A renewal invoice for a hosting subscription: matched by the subscription id (one customer can host several bots). */
create or replace function public.bot_hosting_renew(p_sub text, p_days int default 31) returns timestamptz
language sql security definer set search_path = public as $$
  update public.bot_hosting set until = greatest(now(), coalesce(until, now())) + make_interval(days => p_days), updated_at = now()
  where stripe_sub = p_sub and p_sub is not null
  returning until;
$$;

-- All of these are for the service role only (API routes).
revoke all on function public.bot_hosting_hit(uuid, text, int, int) from public, anon, authenticated;
revoke all on function public.bot_hosting_stop_reason(uuid, boolean) from public, anon, authenticated;
revoke all on function public.bot_hosting_apply_report(text, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.bot_hosting_paid(uuid, uuid, text, text, text, int, numeric) from public, anon, authenticated;
revoke all on function public.bot_hosting_renew(text, int) from public, anon, authenticated;
grant execute on function public.bot_hosting_hit(uuid, text, int, int) to service_role;
grant execute on function public.bot_hosting_stop_reason(uuid, boolean) to service_role;
grant execute on function public.bot_hosting_apply_report(text, jsonb, boolean) to service_role;
grant execute on function public.bot_hosting_paid(uuid, uuid, text, text, text, int, numeric) to service_role;
grant execute on function public.bot_hosting_renew(text, int) to service_role;

insert into public.feature_flags (key, label, description, mode, servers)
values ('bot_hosting', 'Bot hosting', 'Run verified bots on Yapper: upload bot.js or a GitHub repo, Small or Large plan per bot', 'test', '{}')
on conflict (key) do nothing;
