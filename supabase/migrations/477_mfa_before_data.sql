-- 477: No data before the 2FA code (security report Oct 25, "Profil data loading before 2fa code").
-- Signing in with the password gives a session at aal1 even when the account has 2FA; the app then asks for the
-- code, but the aal1 token already worked on the API (channel_messages and every table). Only the staff routes
-- checked for aal2. Now request_guard (PostgREST's db_pre_request, runs once per API request) refuses an aal1
-- token from an account that has a verified 2FA factor, with 403 "Finish signing in with your 2FA code".
-- The 2FA challenge itself goes to Supabase Auth, not PostgREST, so it keeps working.
-- Cost: one probe on mfa_factors_user_id_idx (live, checked Oct 25) per signed-in request that isn't aal2, which is
-- nearly all of them (accounts without 2FA and bot tokens are aal1). It sits next to the request_throttle probe that
-- was already there and touches a small table (1768 accounts had 2FA on Oct 25). aal2 tokens skip it.
-- Not covered here (follow-ups): our realtime server (ops/realtime) and the Next API routes accept any valid
-- token; they need the same aal check.
-- Re-runnable (create or replace). DDL: apply in quiet hours, and not while the Oct 25 freeze is on.

create or replace function public.request_guard()
 returns void
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  claims text := nullif(current_setting('request.jwt.claims', true), '');
  sub text;
  aal text;
  uid uuid;
  till timestamptz;
  enf boolean;
begin
  if claims is not null then
    sub := claims::jsonb ->> 'sub';
    aal := claims::jsonb ->> 'aal';
  else
    sub := nullif(current_setting('request.jwt.claim.sub', true), '');
    aal := nullif(current_setting('request.jwt.claim.aal', true), '');
  end if;
  if sub is null then return; end if;
  if sub !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return; end if;
  uid := sub::uuid;

  -- 218: who this (verified) request is from, for the per-account counts on our own API host.
  perform set_config('response.headers', '[{"X-Yapper-Uid": "' || uid::text || '"}]', true);

  -- 477: password done but not the 2FA code yet.
  if coalesce(aal, 'aal1') <> 'aal2'
     and exists (select 1 from auth.mfa_factors f where f.user_id = uid and f.status = 'verified') then
    raise sqlstate 'PT403' using
      message = 'Finish signing in with your 2FA code.',
      hint = 'This account has 2FA on. A session that has not passed the code can''t read or change anything.';
  end if;

  select t.until, t.enforced into till, enf from public.request_throttle t where t.user_id = uid;
  if not found or not enf or till <= now() then return; end if;

  if not exists (
    select 1 from public.feature_flags f
    where f.key = 'request_limits' and (f.mode = 'everyone' or (f.mode = 'test' and uid = any(f.users)))
  ) then return; end if;

  raise sqlstate 'PT429' using
    message = 'Too many requests from your account. Try again after ' || to_char(till at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC.',
    hint = 'Yapper limits how often one account can call the API. Slow your script down.';
end $function$;
