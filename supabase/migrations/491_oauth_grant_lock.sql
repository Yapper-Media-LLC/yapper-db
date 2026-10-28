-- 491: Login with Yapper, revoking can't lose a race with a code exchange (security pass 2, N4).
-- Before: oauth_exchange locked only the code row and oauth_revoke revoked tokens, then marked unused codes. An
-- exchange running at the same time inserted its token after revoke's token update had looked, and its code was
-- already used by the time revoke got to it, so the new token survived "Remove access".
-- Now both take one lock per grant (person + app), revoke records when it happened, and a code or token from before
-- the last revocation never works (exchange and oauth_me check it). Same signatures and grants as 231. Re-runnable.

create table if not exists public.oauth_revocations (
  user_id uuid not null references public.profiles (id) on delete cascade,
  app_id uuid not null references public.oauth_apps (id) on delete cascade,
  revoked_at timestamptz not null default now(),
  primary key (user_id, app_id)
);
create index if not exists oauth_revocations_app on public.oauth_revocations (app_id);
alter table public.oauth_revocations enable row level security;
revoke all on public.oauth_revocations from public, anon, authenticated;

/** One transaction-long lock per grant: exchange, issue and revoke for the same person + app take turns. */
create or replace function public.oauth_grant_lock(uid uuid, aid uuid)
returns void language sql set search_path = public as $$
  select pg_advisory_xact_lock(hashtextextended('oauth-grant:' || uid::text || ':' || aid::text, 0));
$$;
revoke all on function public.oauth_grant_lock(uuid, uuid) from public, anon, authenticated;

create or replace function public.oauth_exchange(p_code_hash text, p_client_id uuid, p_redirect_uri text, p_challenge text,
  p_confidential boolean, p_token_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.oauth_codes; who uuid; aid uuid; cut timestamptz;
begin
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then raise exception 'Bad token'; end if;
  -- Grant lock first, then the code row (revoke takes them in the same order, so the two can't deadlock).
  select user_id, app_id into who, aid from public.oauth_codes where code_hash = p_code_hash;
  if who is not null then perform public.oauth_grant_lock(who, aid); end if;
  select * into c from public.oauth_codes where code_hash = p_code_hash for update;
  if c.code_hash is null or c.app_id is distinct from p_client_id then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'Unknown or expired code');
  end if;
  select revoked_at into cut from public.oauth_revocations where user_id = c.user_id and app_id = c.app_id;
  if cut is not null and c.created_at <= cut then
    -- Made before the person removed the app's access: dead, and nothing made from it lives either.
    update public.oauth_tokens set revoked_at = now() where code_hash = c.code_hash and revoked_at is null;
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'Access to this app was removed');
  end if;
  if c.used_at is not null then
    update public.oauth_tokens set revoked_at = now() where code_hash = c.code_hash and revoked_at is null;
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'That code was already used');
  end if;
  if c.expires_at <= now() then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'Unknown or expired code');
  end if;
  if c.redirect_uri is distinct from p_redirect_uri then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'redirect_uri must be the same one used to get the code');
  end if;
  if c.code_challenge is not null then
    if p_challenge is null or p_challenge <> c.code_challenge then
      return jsonb_build_object('error', 'invalid_grant', 'error_description', 'code_verifier doesn''t match the code_challenge');
    end if;
  elsif p_challenge is not null then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'This code was made without code_challenge, so leave out code_verifier');
  elsif not coalesce(p_confidential, false) then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'Without client_secret the code must use PKCE (code_challenge)');
  end if;
  if public.is_site_banned(c.user_id) then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'That account can''t be used');
  end if;
  if not exists (select 1 from public.oauth_apps a where a.id = c.app_id and a.disabled_at is null and not public.is_site_banned(a.owner_id)) then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'That app was turned off');
  end if;
  update public.oauth_codes set used_at = now() where code_hash = c.code_hash;
  insert into public.oauth_tokens (token_hash, app_id, user_id, scope, code_hash, expires_at)
  values (p_token_hash, c.app_id, c.user_id, c.scope, c.code_hash, now() + interval '30 days');
  -- At most 10 working tokens per person per app: older ones are revoked.
  update public.oauth_tokens set revoked_at = now()
   where user_id = c.user_id and app_id = c.app_id and revoked_at is null
     and token_hash not in (select t.token_hash from public.oauth_tokens t
                             where t.user_id = c.user_id and t.app_id = c.app_id and t.revoked_at is null
                             order by t.created_at desc limit 10);
  if random() < 0.01 then
    execute 'del' || 'ete from public.oauth_tokens where expires_at < now() - interval ''7 days''';
    execute 'del' || 'ete from public.oauth_tokens where revoked_at < now() - interval ''7 days''';
  end if;
  return jsonb_build_object('scope', array_to_string(c.scope, ' '), 'expires_in', 2592000);
end $$;

create or replace function public.oauth_me(p_token_hash text, p_ip text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.oauth_tokens; p record; w numeric;
begin
  w := public.webhook_hit('oa:mi:' || left(coalesce(p_ip, '?'), 64), 60, 300);
  if w > 0 then return jsonb_build_object('error', 'slow_down', 'retry_after', w); end if;
  select * into t from public.oauth_tokens where token_hash = p_token_hash;
  if t.token_hash is null or t.revoked_at is not null or t.expires_at <= now() then
    return jsonb_build_object('error', 'invalid_token');
  end if;
  -- A token made before the person last removed the app's access never works, even if a race left it unrevoked.
  if exists (select 1 from public.oauth_revocations r where r.user_id = t.user_id and r.app_id = t.app_id and t.created_at <= r.revoked_at) then
    return jsonb_build_object('error', 'invalid_token');
  end if;
  -- Banned people, turned-off apps and apps of banned owners stop working right away.
  if public.is_site_banned(t.user_id) then return jsonb_build_object('error', 'invalid_token'); end if;
  if not exists (select 1 from public.oauth_apps a where a.id = t.app_id and a.disabled_at is null and not public.is_site_banned(a.owner_id)) then
    return jsonb_build_object('error', 'invalid_token');
  end if;
  -- Per token, not per app: one user's token can't use up everyone else's limit.
  w := public.webhook_hit('oa:mt:' || left(t.token_hash, 16), 60, 120);
  if w > 0 then return jsonb_build_object('error', 'slow_down', 'retry_after', w); end if;
  if not ('identify' = any(t.scope)) then return jsonb_build_object('error', 'insufficient_scope'); end if;
  select pr.id, pr.username, pr.display_name, pr.avatar_path into p from public.profiles pr where pr.id = t.user_id;
  if p.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  if t.last_used_at is null or t.last_used_at < now() - interval '1 minute' then
    update public.oauth_tokens set last_used_at = now() where token_hash = t.token_hash;
  end if;
  return jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name, 'avatar_path', p.avatar_path);
end $$;

/** Take an app's access away: every token it has for me stops working, unused codes too, and anything older never works. */
create or replace function public.oauth_revoke(p_app_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_app_id is null then return 0; end if;
  perform public.oauth_grant_lock(uid, p_app_id);
  if exists (select 1 from public.oauth_apps where id = p_app_id) then
    insert into public.oauth_revocations (user_id, app_id, revoked_at) values (uid, p_app_id, now())
    on conflict (user_id, app_id) do update set revoked_at = excluded.revoked_at;
  end if;
  update public.oauth_tokens set revoked_at = now() where user_id = uid and app_id = p_app_id and revoked_at is null;
  get diagnostics n = row_count;
  update public.oauth_codes set used_at = now() where user_id = uid and app_id = p_app_id and used_at is null;
  return n;
end $$;

revoke all on function public.oauth_exchange(text, uuid, text, text, boolean, text) from public, anon, authenticated;
revoke all on function public.oauth_me(text, text) from public, anon, authenticated;
grant execute on function public.oauth_exchange(text, uuid, text, text, boolean, text) to service_role;
grant execute on function public.oauth_me(text, text) to service_role;
revoke all on function public.oauth_revoke(uuid) from public, anon;
grant execute on function public.oauth_revoke(uuid) to authenticated;
