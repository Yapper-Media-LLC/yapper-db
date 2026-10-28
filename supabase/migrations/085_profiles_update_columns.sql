-- Profiles: people could PATCH any column of their own row (applied live Oct 14). Bug report 824f55ad:
-- self-granted Plus (plus_until), a fake verified_as, self-unmute, badges. The row-level policy only
-- checks id = auth.uid(); column privileges now say which columns a user may change. Everything else is
-- written by security-definer functions, triggers and the service role, which are not affected.
revoke update (id, created_at, badges, plus_until, verified_as, muted_until, muted_reason, voice_muted_until, stripe_customer)
  on public.profiles from authenticated, anon;
