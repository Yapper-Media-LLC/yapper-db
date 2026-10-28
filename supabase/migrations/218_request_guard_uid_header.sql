-- 218: request limits see api.yapper.website again.
--
-- Why: since Oct 17 ~21:15 UTC the browser's REST calls go to our own PostgREST (api.yapper.website, ops/api), and the
-- request-limits detector (app/api/cron/request-limits, migration 190) only read Supabase's gateway logs, so a script
-- hitting our API was never counted. Caddy there can't tell whose request it was without the token, and the token must
-- not end up in any log.
--
-- What: request_guard (PostgREST's db-pre-request hook, runs only AFTER PostgREST has verified the JWT; a bad or
-- forged token is answered 401 before it) now also adds the response header  X-Yapper-Uid: <the token's sub>.
-- Caddy logs that header (log_append yapper_uid, see ops/api/README.md "Request counts"), and yapper-api-usage on the
-- API host counts accepted requests per account from that log. So the account a request is counted against is
-- always one PostgREST checked the signature of; nothing on the box handles or stores tokens.
--
-- The header goes to the browser too, which is harmless: it is the caller's own id, from the token the caller sent,
-- and it is not in Access-Control-Expose-Headers, so other sites' scripts can't read it. Supabase's own gateway
-- passes it on the same way (its counts still come from its logs). No function in the database sets
-- response.headers itself (checked live, Oct 18), so nothing overwrites it.
-- Cost: one set_config per signed-in request, no table access added.
--
-- Same signature as 190's, so create or replace is safe while the hook is on (see 190's CAREFUL note).
-- Re-runnable.

create or replace function public.request_guard()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  claims text := nullif(current_setting('request.jwt.claims', true), '');
  sub text;
  uid uuid;
  till timestamptz;
  enf boolean;
begin
  -- PostgREST (v10+) sets request.jwt.claims; the old per-claim setting is only a fallback.
  if claims is not null then
    sub := claims::jsonb ->> 'sub';
  else
    sub := nullif(current_setting('request.jwt.claim.sub', true), '');
  end if;
  if sub is null then return; end if;               -- no token / anon key / service role / publishable key: no user
  -- Only a real user id; anything else (never seen from Supabase Auth) is let through rather than erroring.
  if sub !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return; end if;
  uid := sub::uuid;

  -- 218: who this (verified) request is from, for the per-account counts on our own API host. uid::text is a
  -- canonical uuid, so the JSON can't be broken by the value.
  perform set_config('response.headers', '[{"X-Yapper-Uid": "' || uid::text || '"}]', true);

  select t.until, t.enforced into till, enf from public.request_throttle t where t.user_id = uid;
  if not found or not enf or till <= now() then return; end if;

  -- Rare path (someone is held back): is the feature on for them?
  if not exists (
    select 1 from public.feature_flags f
    where f.key = 'request_limits' and (f.mode = 'everyone' or (f.mode = 'test' and uid = any(f.users)))
  ) then return; end if;

  raise sqlstate 'PT429' using
    message = 'Too many requests from your account. Try again after ' || to_char(till at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC.',
    hint = 'Yapper limits how often one account can call the API. Slow your script down.';
end $$;
revoke all on function public.request_guard() from public;
grant execute on function public.request_guard() to anon, authenticated, service_role;
