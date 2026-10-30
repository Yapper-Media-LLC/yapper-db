-- 632: Boosts and Promoted spots (servers and bots) as monthly subscriptions (flag promo_subs, test). Antic, Oct 28:
-- "turn all promotions and so on into subscriptions". Same flow as Plus / Bots+ / Supercharge: Checkout in
-- subscription mode (prices inline, no Stripe products), the first invoice is booked by the checkout event, every
-- later invoice.paid adds a month to the same row, customer.subscription.deleted ends it at the paid period's end.
-- The row keeps the subscription id (stripe_sub) so Settings > Subscriptions can list and cancel it and the renewal
-- knows which row to extend. One-off rows (stripe_sub null) keep running out as before. Re-runnable.
set lock_timeout = '3s';

alter table public.server_promotions add column if not exists stripe_sub text;
alter table public.bot_promotions add column if not exists stripe_sub text;
-- One row per subscription: two checkout events for one session (completed + async_payment_succeeded, or a retry
-- racing a slow first try) can't both book; the second insert fails with 23505, which the webhook counts as a dup.
create unique index if not exists server_promotions_sub_idx on public.server_promotions (stripe_sub) where stripe_sub is not null;
create unique index if not exists bot_promotions_sub_idx on public.bot_promotions (stripe_sub) where stripe_sub is not null;
-- bot_promotions uses column grants (441): the owner's page needs to know which rows renew by themselves.
grant select (stripe_sub) on public.bot_promotions to authenticated;

-- A Discovery placement bought as a subscription: books like a one-off (the live book_promotion always inserts a row:
-- a Promoted spot is queued, a boost of a running tier starts after it) and remembers the subscription. The same subscription twice (two
-- checkout events for one session, a replay) books nothing new. service_role only.
create or replace function public.book_promotion_sub(sid uuid, p_kind text, p_mult int, p_sub text, p_event text, p_by uuid, p_days int default 31)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_start timestamptz;
begin
  if p_sub is null or p_sub !~ '^sub_[A-Za-z0-9]+$' then raise exception 'subscription id required'; end if;
  if p_kind not in ('promote', 'boost') then raise exception 'Unknown kind'; end if;
  if p_days is null or p_days < 1 or p_days > 60 then raise exception 'Pick 1 to 60 days'; end if;
  select starts_at into v_start from public.server_promotions where stripe_sub = p_sub order by starts_at limit 1;
  if v_start is not null then return v_start; end if;
  v_start := public.book_promotion(sid, p_kind, 'stripe', p_event, p_by, p_days, coalesce(p_mult, 4));
  update public.server_promotions set stripe_sub = p_sub where stripe_event = p_event and stripe_sub is null;
  return v_start;
end $$;

-- Same for a bot (Promoted spot or boost in the bot list).
create or replace function public.book_bot_placement_sub(bid uuid, p_kind text, p_mult int, p_sub text, p_event text, p_by uuid, p_days int default 31)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_start timestamptz;
begin
  if p_sub is null or p_sub !~ '^sub_[A-Za-z0-9]+$' then raise exception 'subscription id required'; end if;
  if p_kind not in ('promote', 'boost') then raise exception 'Unknown kind'; end if;
  if p_days is null or p_days < 1 or p_days > 60 then raise exception 'Pick 1 to 60 days'; end if;
  select starts_at into v_start from public.bot_promotions where stripe_sub = p_sub order by starts_at limit 1;
  if v_start is not null then return v_start; end if;
  if p_kind = 'promote' then
    v_start := public.book_bot_promotion(bid, 'stripe', p_event, p_by, p_days);
  else
    v_start := public.book_bot_boost(bid, p_mult, 'stripe', p_event, p_by, p_days);
  end if;
  update public.bot_promotions set stripe_sub = p_sub where stripe_event = p_event and stripe_sub is null;
  return v_start;
end $$;

-- Which placement a subscription pays for: {"table": "server"|"bot", "target": id, "kind", "mult", "ends_at"} or null.
create or replace function public.placement_for_sub(p_sub text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('table', 'server', 'target', p.server_id, 'kind', p.kind, 'mult', p.mult, 'ends_at', p.ends_at)
       from public.server_promotions p where p.stripe_sub = p_sub order by p.ends_at desc limit 1),
    (select jsonb_build_object('table', 'bot', 'target', p.bot_id, 'kind', p.kind, 'mult', p.mult, 'ends_at', p.ends_at)
       from public.bot_promotions p where p.stripe_sub = p_sub order by p.ends_at desc limit 1));
$$;

-- A paid renewal: one more month on the subscription's row, once per invoice (billing_fulfilments, like Plus).
-- A row that already ran out (a late payment) starts again now; a queued spot keeps its place in the queue. A
-- placement staff ended (its cancellation is queued in stripe_cancel_jobs, the cron may not have reached Stripe yet)
-- is never brought back by a payment. Returns the new end, or the current one for a repeat.
create or replace function public.renew_placement_once(p_sub text, p_days int, p_business text, p_event text)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare got text; v_end timestamptz;
begin
  if coalesce(p_business, '') = '' then raise exception 'business id required'; end if;
  if p_days is null or p_days < 1 or p_days > 60 then raise exception 'bad renewal'; end if;
  if public.placement_for_sub(p_sub) is null then raise exception 'subscription unknown'; end if;
  insert into public.billing_fulfilments (business_id, kind, event_id) values (p_business, 'placement', p_event)
    on conflict (business_id) do nothing returning business_id into got;
  if got is null or exists (select 1 from public.stripe_cancel_jobs where sub = p_sub) then
    return (public.placement_for_sub(p_sub) ->> 'ends_at')::timestamptz;
  end if;
  update public.server_promotions set starts_at = case when ends_at < now() then now() else starts_at end,
         ends_at = greatest(now(), ends_at) + make_interval(days => p_days)
   where stripe_sub = p_sub returning ends_at into v_end;
  if v_end is null then
    update public.bot_promotions set starts_at = case when ends_at < now() then now() else starts_at end,
           ends_at = greatest(now(), ends_at) + make_interval(days => p_days)
     where stripe_sub = p_sub returning ends_at into v_end;
  end if;
  return v_end;
end $$;

-- The subscription ended (customer.subscription.deleted): the placement stops at the paid period's end (p_at, from the
-- event), never later than it already would. A queued spot that hadn't started by then is dropped. Returns rows touched.
create or replace function public.end_placement_sub(p_sub text, p_at timestamptz default null)
returns int language plpgsql security definer set search_path = public as $$
declare cut timestamptz := greatest(now(), coalesce(p_at, now())); n int := 0; m int := 0;
begin
  update public.server_promotions set ends_at = cut, starts_at = least(starts_at, cut) where stripe_sub = p_sub and ends_at > cut;
  get diagnostics n = row_count;
  update public.bot_promotions set ends_at = cut, starts_at = least(starts_at, cut) where stripe_sub = p_sub and ends_at > cut;
  get diagnostics m = row_count;
  return n + m;
end $$;

-- Staff ending a placement that renews by itself must also stop the billing: queued for Stripe (stripe_cancel_jobs,
-- retried by /api/cron/stripe-cancels), so nobody keeps paying for a spot that was taken away.
create or replace function public.admin_end_promotion(pid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_sub text;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.server_promotions set ends_at = now() where id = pid and ends_at > now() returning stripe_sub into v_sub;
  if v_sub is not null then perform public.stripe_cancel_later(v_sub, 'promotion ended by admin'); end if;
end $$;

create or replace function public.staff_end_bot_promotion(pid uuid, why text)
returns void language plpgsql security definer set search_path = public as $$
declare v_bot uuid; v_sub text;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if nullif(btrim(coalesce(why, '')), '') is null then raise exception 'Say why'; end if;
  update public.bot_promotions set starts_at = least(starts_at, now()), ends_at = now(), ended_by = (select auth.uid())
  where id = pid and ends_at > now()
  returning bot_id, stripe_sub into v_bot, v_sub;
  if v_bot is null then raise exception 'That promotion already ended'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'bot_promo_ended', v_bot, left(btrim(why), 500));
  if v_sub is not null then perform public.stripe_cancel_later(v_sub, 'bot promotion ended by staff'); end if;
end $$;

-- A deleted server or bot takes its placement rows with it (cascade): stop the billing too, or the subscription
-- would charge on with nothing to extend.
create or replace function public.placement_sub_cancel_on_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.stripe_sub is not null and old.ends_at > now() then perform public.stripe_cancel_later(old.stripe_sub, tg_table_name || ' row deleted'); end if;
  return old;
end $$;
drop trigger if exists server_promotions_sub_cancel on public.server_promotions;
create trigger server_promotions_sub_cancel before delete on public.server_promotions for each row execute function public.placement_sub_cancel_on_delete();
drop trigger if exists bot_promotions_sub_cancel on public.bot_promotions;
create trigger bot_promotions_sub_cancel before delete on public.bot_promotions for each row execute function public.placement_sub_cancel_on_delete();
revoke all on function public.placement_sub_cancel_on_delete() from public, anon, authenticated;

revoke all on function public.book_promotion_sub(uuid, text, int, text, text, uuid, int), public.book_bot_placement_sub(uuid, text, int, text, text, uuid, int),
  public.placement_for_sub(text), public.renew_placement_once(text, int, text, text), public.end_placement_sub(text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.book_promotion_sub(uuid, text, int, text, text, uuid, int), public.book_bot_placement_sub(uuid, text, int, text, text, uuid, int),
  public.placement_for_sub(text), public.renew_placement_once(text, int, text, text), public.end_placement_sub(text, timestamptz)
  to service_role;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('promo_subs', 'Promotions as subscriptions', 'Boosts and Promoted spots (servers and bots) are bought as monthly subscriptions that renew until cancelled in Settings > Subscriptions, instead of 7-day one-offs.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
reset lock_timeout;
