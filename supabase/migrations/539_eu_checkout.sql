-- 539: EU checkout (flag eu_checkout, test). Legal list B7, Terms 9.3 / 9.5.
--  - checkout_consents: buyers in the EU, EEA, UK and Switzerland tick a separate, unticked "Start now" box before
--    Stripe opens (the checkbox Stripe shows only covers the Terms). Each tick is kept as proof.
--  - withdrawals: "Withdraw from contract" in Settings, Subscriptions, within 14 days of a subscription starting:
--    cancelled at once, unused time taken back, the unused part refunded through Stripe. A refund Stripe refused waits
--    in Mod Center, Withdrawals, for staff to do by hand.
--  - cancel_requests: the public /cancel page ("Verträge hier kündigen", German BGB 312k) for people who aren't
--    signed in: a confirmation link goes to the account's email, and the click cancels at the end of the period.
-- All three are written by the server (service role) only; RLS on, no policies. Staff read withdrawals through
-- admin-checked functions. Re-runnable.

create table if not exists public.checkout_consents (
  id bigserial primary key,
  user_id uuid not null,
  kind text not null,
  target text,
  country text,
  waiver_text text not null,
  terms_version text not null,
  created_at timestamptz not null default now()
);
create index if not exists checkout_consents_user_idx on public.checkout_consents (user_id, created_at desc);
alter table public.checkout_consents enable row level security;
revoke all on public.checkout_consents from anon, authenticated;

create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  stripe_sub text not null unique,
  label text,
  paid_cents integer,
  refund_cents integer,
  currency text,
  stripe_refund text,
  status text not null check (status in ('refunded', 'refund_failed', 'manual_done')),
  error text,
  note text,
  created_at timestamptz not null default now(),
  handled_by uuid,
  handled_at timestamptz
);
create index if not exists withdrawals_user_idx on public.withdrawals (user_id);
create index if not exists withdrawals_status_idx on public.withdrawals (status, created_at desc);
alter table public.withdrawals enable row level security;
revoke all on public.withdrawals from anon, authenticated;

create table if not exists public.cancel_requests (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  what text not null check (what in ('all', 'plus', 'bots_plus', 'supercharge', 'bot_hosting')),
  details text,
  token_hash text not null unique,
  ip_hash text,
  user_id uuid,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  result text
);
create index if not exists cancel_requests_ip_idx on public.cancel_requests (ip_hash, created_at desc);
create index if not exists cancel_requests_email_idx on public.cancel_requests (email, created_at desc);
alter table public.cancel_requests enable row level security;
revoke all on public.cancel_requests from anon, authenticated;

-- Mod Center, Withdrawals. p_open: only refunds that still need doing by hand.
create or replace function public.staff_withdrawals(p_open boolean default true)
returns table (
  id uuid, user_id uuid, username text, stripe_sub text, label text, paid_cents integer, refund_cents integer,
  currency text, stripe_refund text, status text, error text, note text, created_at timestamptz, handled_at timestamptz
) language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  return query
  select w.id, w.user_id, p.username, w.stripe_sub, w.label, w.paid_cents, w.refund_cents, w.currency, w.stripe_refund,
    w.status, w.error, w.note, w.created_at, w.handled_at
  from public.withdrawals w
  left join public.profiles p on p.id = w.user_id
  where not p_open or w.status = 'refund_failed'
  order by w.created_at desc
  limit 200;
end $$;

-- Staff refunded it by hand in Stripe.
create or replace function public.staff_withdrawal_done(p_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  w public.withdrawals;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.withdrawals set status = 'manual_done', note = nullif(left(trim(coalesce(p_note, '')), 500), ''),
    handled_by = auth.uid(), handled_at = now()
  where id = p_id and status = 'refund_failed'
  returning * into w;
  if not found then raise exception 'Nothing to do for that one'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'withdrawal_refunded', w.user_id, left(w.stripe_sub || ' ' || coalesce(p_note, ''), 120));
end $$;

revoke all on function public.staff_withdrawals(boolean) from public, anon;
revoke all on function public.staff_withdrawal_done(uuid, text) from public, anon;
grant execute on function public.staff_withdrawals(boolean) to authenticated;
grant execute on function public.staff_withdrawal_done(uuid, text) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('eu_checkout', 'EU checkout', 'Separate "Start now" box before checkout for EU/EEA/UK/CH buyers (logged), no checkout from sanctioned countries, Withdraw from contract in Subscriptions (14 days, pro-rata refund), purchase and renewal emails, public /cancel page. Test: Antic only', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
