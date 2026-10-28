-- 143: Stripe audit trail. The webhook now stores what was paid on every event it sees, and why it
-- refused one (note), so odd payments can be traced. Read only with the service role.
alter table public.plus_events add column if not exists amount int, add column if not exists currency text,
  add column if not exists ref text, add column if not exists email text, add column if not exists note text;
revoke all on public.plus_events from anon, authenticated;
