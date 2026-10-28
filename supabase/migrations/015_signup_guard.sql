-- ============================================================
-- Yapper · Don't let a viral spike break sign-ups
-- The sign-up route logs every confirmation email it causes. Once too
-- many went out in the last 24h (the email provider's daily cap), new
-- accounts are created already confirmed instead of waiting for an email.
-- Only the server (service role) touches these tables.
-- ============================================================

create table public.email_log (
  id bigint generated always as identity primary key,
  kind text not null,
  sent_at timestamptz not null default now()
);
create index email_log_sent_idx on public.email_log (sent_at desc);
alter table public.email_log enable row level security;

create table public.signup_log (
  id bigint generated always as identity primary key,
  ip text not null,
  created_at timestamptz not null default now()
);
create index signup_log_ip_idx on public.signup_log (ip, created_at desc);
alter table public.signup_log enable row level security;
