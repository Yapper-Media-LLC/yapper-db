-- 493: Stripe fulfilment that can't be lost or doubled (security pass 2, B1-B3). Re-runnable.
-- Before: the webhook wrote its plus_events row first and treated any insert error as "already done", so a delivery
-- that failed half way and returned 500 was skipped on Stripe's retry (paid, nothing granted). Plus and Server Plus
-- were extended read, add a month, write, so two payments at once could leave one month. Cancelling an old
-- subscription (plan switch, deleted bot) was tried once and forgotten.
--
-- 1. plus_events is an inbox: state pending/done, claimed_at, attempts, business_id (the checkout session or invoice,
--    for looking things up; it doesn't dedupe events, see billing_event_claim).
--    billing_event_claim says go / dup / busy; billing_event_finish marks done, or releases the claim for a retry.
-- 2. extend_plus / extend_server_plus extend in one UPDATE and record the business id in billing_fulfilments, so
--    the same payment (two events for one checkout, a replay) never counts twice.
-- 3. server_plus remembers who paid and the subscription id (managers who pay can see and cancel).
-- 4. stripe_cancel_jobs keeps cancellations until Stripe confirms them; /api/cron/stripe-cancels retries them.
-- Existing plus_events rows become done (they were handled by the old code).

alter table public.plus_events add column if not exists state text not null default 'done';
alter table public.plus_events add column if not exists claimed_at timestamptz;
alter table public.plus_events add column if not exists attempts integer not null default 0;
alter table public.plus_events add column if not exists business_id text;
alter table public.plus_events add column if not exists done_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'plus_events_state_check') then
    alter table public.plus_events add constraint plus_events_state_check check (state in ('pending', 'done'));
  end if;
end $$;
create index if not exists plus_events_business_idx on public.plus_events (business_id) where business_id is not null;
create index if not exists plus_events_pending_idx on public.plus_events (created_at) where state = 'pending';

create table if not exists public.billing_fulfilments (
  business_id text primary key,
  kind text not null,
  target uuid,
  event_id text,
  at timestamptz not null default now()
);
alter table public.billing_fulfilments enable row level security;
revoke all on public.billing_fulfilments from public, anon, authenticated;

alter table public.server_plus add column if not exists payer_id uuid references public.profiles (id) on delete set null;
alter table public.server_plus add column if not exists stripe_sub text;
create index if not exists server_plus_payer_idx on public.server_plus (payer_id) where payer_id is not null;
create index if not exists server_plus_customer_idx on public.server_plus (stripe_customer) where stripe_customer is not null;

create table if not exists public.stripe_cancel_jobs (
  sub text primary key check (sub ~ '^sub_[A-Za-z0-9]+$'),
  reason text not null default '',
  attempts integer not null default 0,
  last_error text,
  next_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists stripe_cancel_jobs_due_idx on public.stripe_cancel_jobs (next_at) where done_at is null;
alter table public.stripe_cancel_jobs enable row level security;
revoke all on public.stripe_cancel_jobs from public, anon, authenticated;

/**
 * Start handling a Stripe event. 'go': handle it now (new, or an earlier try failed / timed out after 2 minutes).
 * 'dup': already done. 'busy': another delivery is handling it right now (answer 409 so Stripe retries later).
 * Not deduped by business id here: a checkout that completed unpaid is done, and its async_payment_succeeded (same
 * session) must still run. One payment never counts twice because each grant checks its own key
 * (billing_fulfilments, plus_gifts / promotions stripe_event, bot_hosting_paid and grant_supercharge by sub).
 */
create or replace function public.billing_event_claim(p_id text, p_kind text, p_business text)
returns text language plpgsql security definer set search_path = public as $$
declare st text; got text;
begin
  if coalesce(p_id, '') = '' then raise exception 'event id required'; end if;
  insert into public.plus_events (id, kind, business_id, state, claimed_at, attempts)
    values (p_id, left(coalesce(p_kind, ''), 80), p_business, 'pending', now(), 1)
    on conflict (id) do nothing
    returning id into got;
  if got is not null then return 'go'; end if;
  update public.plus_events set claimed_at = now(), attempts = attempts + 1, business_id = coalesce(business_id, p_business)
   where id = p_id and state = 'pending' and (claimed_at is null or claimed_at < now() - interval '2 minutes')
   returning id into got;
  if got is not null then return 'go'; end if;
  select state into st from public.plus_events where id = p_id;
  return case when st = 'done' then 'dup' else 'busy' end;
end $$;

/** Finish an event: done (with an optional note), or released so Stripe's next retry handles it again. */
create or replace function public.billing_event_finish(p_id text, p_ok boolean, p_note text default null)
returns void language sql security definer set search_path = public as $$
  update public.plus_events
     set state = case when p_ok then 'done' else 'pending' end,
         done_at = case when p_ok then now() else null end,
         claimed_at = case when p_ok then claimed_at else null end,
         note = coalesce(left(p_note, 500), note)
   where id = p_id;
$$;

/** One payment = one month (or p_days) of Plus, added in one statement. Same business id again: no change. */
create or replace function public.extend_plus(p_user uuid, p_days integer, p_business text, p_event text)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare until timestamptz; got text;
begin
  if p_user is null or coalesce(p_days, 0) < 1 or p_days > 400 then raise exception 'bad plus extension'; end if;
  if coalesce(p_business, '') = '' then raise exception 'business id required'; end if;
  insert into public.billing_fulfilments (business_id, kind, target, event_id) values (p_business, 'plus', p_user, p_event)
    on conflict (business_id) do nothing returning business_id into got;
  if got is null then
    select plus_until into until from public.profiles where id = p_user;
    return until;
  end if;
  update public.profiles set plus_until = greatest(now(), coalesce(plus_until, now())) + make_interval(days => p_days)
   where id = p_user returning plus_until into until;
  if until is null then raise exception 'user not found'; end if;
  return until;
end $$;

/** Server Plus (Bots+) for a payment: extend in one statement, remember the customer, subscription and payer. */
create or replace function public.extend_server_plus(p_server uuid, p_days integer, p_business text, p_event text,
  p_customer text, p_sub text, p_payer uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare until timestamptz; got text;
begin
  if p_server is null or coalesce(p_days, 0) < 1 or p_days > 400 then raise exception 'bad server plus extension'; end if;
  if coalesce(p_business, '') = '' then raise exception 'business id required'; end if;
  if not exists (select 1 from public.servers where id = p_server) then raise exception 'server not found'; end if;
  insert into public.billing_fulfilments (business_id, kind, target, event_id) values (p_business, 'server_plus', p_server, p_event)
    on conflict (business_id) do nothing returning business_id into got;
  if got is null then
    select sp.until into until from public.server_plus sp where sp.server_id = p_server;
    return until;
  end if;
  insert into public.server_plus as sp (server_id, until, stripe_customer, stripe_sub, payer_id, updated_at)
    values (p_server, now() + make_interval(days => p_days), p_customer, p_sub, p_payer, now())
    on conflict (server_id) do update
      set until = greatest(now(), coalesce(sp.until, now())) + make_interval(days => p_days),
          stripe_customer = coalesce(excluded.stripe_customer, sp.stripe_customer),
          stripe_sub = coalesce(excluded.stripe_sub, sp.stripe_sub),
          payer_id = coalesce(excluded.payer_id, sp.payer_id),
          updated_at = now()
    returning sp.until into until;
  return until;
end $$;

/** Bot hosting and Supercharge renewals, once per invoice: the renewal and its record commit together. */
create or replace function public.bot_hosting_renew_once(p_sub text, p_days integer, p_business text, p_event text)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare got text; until timestamptz;
begin
  if coalesce(p_business, '') = '' then raise exception 'business id required'; end if;
  insert into public.billing_fulfilments (business_id, kind, event_id) values (p_business, 'bot_hosting', p_event)
    on conflict (business_id) do nothing returning business_id into got;
  if got is null then
    select h.until into until from public.bot_hosting h where h.stripe_sub = p_sub;
    return until;
  end if;
  return public.bot_hosting_renew(p_sub, p_days);
end $$;

create or replace function public.renew_supercharge_once(p_sub text, p_days integer, p_business text, p_event text)
returns uuid language plpgsql security definer set search_path = public as $$
declare got text; id_ uuid;
begin
  if coalesce(p_business, '') = '' then raise exception 'business id required'; end if;
  insert into public.billing_fulfilments (business_id, kind, event_id) values (p_business, 'supercharge', p_event)
    on conflict (business_id) do nothing returning business_id into got;
  if got is null then
    select s.id into id_ from public.supercharges s where s.stripe_sub = p_sub;
    return id_;
  end if;
  return public.renew_supercharge(p_sub, p_days);
end $$;

/** Remember a subscription to cancel until Stripe confirms it. */
create or replace function public.stripe_cancel_later(p_sub text, p_reason text)
returns void language sql security definer set search_path = public as $$
  insert into public.stripe_cancel_jobs (sub, reason) values (p_sub, left(coalesce(p_reason, ''), 200))
  on conflict (sub) do update set done_at = null, next_at = least(public.stripe_cancel_jobs.next_at, now()),
    reason = case when public.stripe_cancel_jobs.done_at is null then public.stripe_cancel_jobs.reason else excluded.reason end;
$$;

/** Up to p_limit cancellations that are due, claimed for 5 minutes. */
create or replace function public.stripe_cancel_due(p_limit integer)
returns setof text language sql security definer set search_path = public as $$
  update public.stripe_cancel_jobs j set next_at = now() + interval '5 minutes', attempts = j.attempts + 1
   where j.sub in (select sub from public.stripe_cancel_jobs where done_at is null and next_at <= now() and attempts < 30
                    order by next_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked)
  returning j.sub;
$$;

/** How a cancellation went: done, or try again later (backing off up to a day). */
create or replace function public.stripe_cancel_result(p_sub text, p_ok boolean, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.stripe_cancel_jobs
     set done_at = case when p_ok then now() else null end,
         last_error = case when p_ok then null else left(p_error, 300) end,
         next_at = case when p_ok then next_at else now() + least(interval '1 day', interval '5 minutes' * power(2, least(attempts, 9))) end
   where sub = p_sub;
$$;

revoke all on function public.billing_event_claim(text, text, text) from public, anon, authenticated;
revoke all on function public.billing_event_finish(text, boolean, text) from public, anon, authenticated;
revoke all on function public.extend_plus(uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.extend_server_plus(uuid, integer, text, text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.bot_hosting_renew_once(text, integer, text, text) from public, anon, authenticated;
revoke all on function public.renew_supercharge_once(text, integer, text, text) from public, anon, authenticated;
revoke all on function public.stripe_cancel_later(text, text) from public, anon, authenticated;
revoke all on function public.stripe_cancel_due(integer) from public, anon, authenticated;
revoke all on function public.stripe_cancel_result(text, boolean, text) from public, anon, authenticated;
grant execute on function public.billing_event_claim(text, text, text) to service_role;
grant execute on function public.billing_event_finish(text, boolean, text) to service_role;
grant execute on function public.extend_plus(uuid, integer, text, text) to service_role;
grant execute on function public.extend_server_plus(uuid, integer, text, text, text, text, uuid) to service_role;
grant execute on function public.bot_hosting_renew_once(text, integer, text, text) to service_role;
grant execute on function public.renew_supercharge_once(text, integer, text, text) to service_role;
grant execute on function public.stripe_cancel_later(text, text) to service_role;
grant execute on function public.stripe_cancel_due(integer) to service_role;
grant execute on function public.stripe_cancel_result(text, boolean, text) to service_role;

-- Flag for what people see: the Subscriptions page lists Bots+ you paid for as a manager, and says when Stripe is
-- unavailable instead of showing an empty list (billing_trust, test).
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('billing_trust', 'Billing: managers see what they pay, honest errors', 'Subscriptions lists Bots+ you paid for on servers you manage, pages past 20, and shows an error instead of an empty list', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- Every 10 minutes: retry cancellations Stripe hasn't confirmed (the route answers at once when there are none).
-- Remove with select cron.unschedule('stripe-cancels-tick').
do $$ begin
  if to_regclass('cron.job') is not null then
  if not exists (select 1 from cron.job where jobname = 'stripe-cancels-tick') then
    perform cron.schedule('stripe-cancels-tick', '*/10 * * * *', $job$
      select net.http_post(
        url := 'https://www.yapper.website/api/cron/stripe-cancels',
        body := '{}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
          'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'request_limits_secret' limit 1)),
        timeout_milliseconds := 30000)
      where exists (select 1 from vault.decrypted_secrets where name = 'request_limits_secret')
        and exists (select 1 from public.stripe_cancel_jobs where done_at is null and next_at <= now() and attempts < 30)
    $job$);
  end if;
  end if;
end $$;
