-- 231: Login with Yapper (an OAuth2 provider, like "Login with Discord"). Flag oauth (test).
--
-- Developers make an app (Developer Portal) and get a client ID (the app id) and a client secret (shown once).
-- A site sends people to /oauth/authorize; after they press Authorize the site gets a one-time code on its
-- redirect URL and swaps it at POST /api/oauth/token for an access token ("yo_..."), then reads
-- GET /api/oauth/me. Only scope "identify" exists: id, username, display name, profile picture.
--
-- Secrets, codes and tokens are made in the Next routes (node:crypto, 32 random bytes) and only their sha256
-- (hex) is stored here. Nothing in this file ever sees a plain secret.
--
--   oauth_apps    one row per app. redirect_uris: exact match, https only (http only for localhost/127.0.0.1).
--   oauth_codes   one-time codes: 60 s, single use, bound to app + user + redirect_uri + PKCE challenge.
--   oauth_tokens  access tokens: 30 days, revocable, last_used_at updated at most once a minute.
--
-- No client policies on any of them: RLS on, all table rights taken away from anon/authenticated. Everything
-- goes through the functions below.
--   authenticated: oauth_my_apps, oauth_update_app, oauth_remove_app, oauth_my_grants, oauth_revoke
--   anon + authenticated: oauth_app_info (the consent page, before and after logging in)
--   service_role only (Next routes): oauth_create_app, oauth_reset_secret, oauth_issue_code, oauth_rate,
--     oauth_exchange, oauth_me
-- Creating an app needs the flag (checked here, for the caller the route verified). The rest works for any app
-- that exists, so a test app can be tried end to end.
-- Rate limits reuse webhook_hit (155): fixed windows in webhook_rate, keys start with "oa:".
-- Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('oauth', 'Login with Yapper', 'Developers make OAuth apps so other sites can offer "Login with Yapper". Adds Authorized Apps to settings.', 'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- Tables ----------

create table if not exists public.oauth_apps (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 40),
  description text not null default '' check (char_length(description) <= 400),
  icon_path text check (icon_path is null or (char_length(icon_path) < 300 and icon_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9_.-]+$')),
  redirect_uris text[] not null default '{}' check (cardinality(redirect_uris) <= 10),
  secret_hash text not null check (secret_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  disabled_at timestamptz
);
create index if not exists oauth_apps_owner on public.oauth_apps (owner_id);
alter table public.oauth_apps enable row level security;
revoke all on public.oauth_apps from public, anon, authenticated;

-- Icons go through the same image check as server icons; names and descriptions through the slur filter.
create or replace trigger oauth_apps_scanned_media before insert or update of icon_path on public.oauth_apps
  for each row execute function public.require_scanned_media('icon_path', 'icons');
create or replace trigger oauth_apps_no_slurs before insert or update of name, description on public.oauth_apps
  for each row execute function public.no_slurs('name', 'description');

create table if not exists public.oauth_codes (
  code_hash text primary key check (code_hash ~ '^[0-9a-f]{64}$'),
  app_id uuid not null references public.oauth_apps (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  redirect_uri text not null,
  scope text[] not null,
  code_challenge text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index if not exists oauth_codes_app on public.oauth_codes (app_id);
create index if not exists oauth_codes_user on public.oauth_codes (user_id, app_id);
create index if not exists oauth_codes_expires on public.oauth_codes (expires_at);
alter table public.oauth_codes enable row level security;
revoke all on public.oauth_codes from public, anon, authenticated;

create table if not exists public.oauth_tokens (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  app_id uuid not null references public.oauth_apps (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  scope text[] not null,
  -- The code it was swapped for: if that code shows up again (stolen and replayed), this token is revoked.
  code_hash text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index if not exists oauth_tokens_user_app on public.oauth_tokens (user_id, app_id);
create index if not exists oauth_tokens_app on public.oauth_tokens (app_id);
create index if not exists oauth_tokens_code on public.oauth_tokens (code_hash) where code_hash is not null;
create index if not exists oauth_tokens_expires on public.oauth_tokens (expires_at);
create index if not exists oauth_tokens_revoked on public.oauth_tokens (revoked_at) where revoked_at is not null;
alter table public.oauth_tokens enable row level security;
revoke all on public.oauth_tokens from public, anon, authenticated;

-- ---------- Helpers (not callable by clients) ----------

/** Is the oauth flag on for this person (everyone, or test mode for listed users / members of listed servers)? */
create or replace function public.oauth_flag_on(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select f.mode = 'everyone' or (f.mode = 'test' and (uid = any(f.users)
    or exists (select 1 from public.server_members m where m.user_id = uid and m.server_id = any(f.servers))))
    from public.feature_flags f where f.key = 'oauth'), false);
$$;

/** 2FA accounts need a session that finished 2FA (aal2), like every other write (require_mfa, 032). */
create or replace function public.oauth_mfa_ok(uid uuid, aal text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(aal, 'aal1') = 'aal2' then return true; end if;
  return not exists (select 1 from auth.mfa_factors f where f.user_id = uid and f.status = 'verified');
end $$;

/**
 * Checked, trimmed, de-duplicated redirect URLs. https://host[:port][/path?query] for real sites; http:// only for
 * localhost, 127.0.0.1 or [::1] (testing). No #fragment, no user:pass@, no spaces or non-ASCII. Up to 10.
 */
create or replace function public.oauth_clean_uris(uris text[])
returns text[] language plpgsql immutable set search_path = public as $$
declare u text; res text[] := '{}';
begin
  if uris is null then return res; end if;
  foreach u in array uris loop
    u := btrim(coalesce(u, ''));
    if u = '' then continue; end if;
    if char_length(u) > 500 then raise exception 'Redirect URLs can be up to 500 characters'; end if;
    if u ~ '[^!-~]'
       or not (u ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^#\\]*)?$'
               or u ~ '^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?(/[^#\\]*)?$') then
      raise exception 'Redirect URLs need https:// (http:// only for localhost or 127.0.0.1) and no #: %', left(u, 80);
    end if;
    if not (u = any(res)) then res := res || u; end if;
  end loop;
  if cardinality(res) > 10 then raise exception 'Up to 10 redirect URLs per app'; end if;
  return res;
end $$;

/** An app as its owner sees it (never the secret hash). */
create or replace function public.oauth_app_json(a public.oauth_apps)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'name', a.name, 'description', a.description, 'icon_path', a.icon_path,
    'redirect_uris', to_jsonb(a.redirect_uris), 'created_at', a.created_at, 'disabled_at', a.disabled_at,
    'users', (select count(distinct t.user_id) from public.oauth_tokens t
               where t.app_id = a.id and t.revoked_at is null and t.expires_at > now()));
$$;

revoke all on function public.oauth_flag_on(uuid) from public, anon, authenticated;
revoke all on function public.oauth_mfa_ok(uuid, text) from public, anon, authenticated;
revoke all on function public.oauth_clean_uris(text[]) from public, anon, authenticated;
revoke all on function public.oauth_app_json(public.oauth_apps) from public, anon, authenticated;

-- ---------- Owners (Developer Portal) ----------

/** Make an app. Called by POST /api/oauth/apps for the signed-in caller it verified; the secret is made there. */
create or replace function public.oauth_create_app(p_owner uuid, p_aal text, p_name text, p_description text, p_redirect_uris text[], p_secret_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name, '')); d text := btrim(coalesce(p_description, '')); uris text[]; a public.oauth_apps;
begin
  if p_owner is null then raise exception 'Not signed in'; end if;
  if not public.oauth_flag_on(p_owner) then raise exception 'Login with Yapper isn''t open yet'; end if;
  if public.is_site_banned(p_owner) then raise exception 'Your account is banned from Yapper'; end if;
  if public.is_bot_user(p_owner) then raise exception 'Bots can''t make apps'; end if;
  if not public.oauth_mfa_ok(p_owner, p_aal) then raise exception 'Finish two-factor sign-in first.'; end if;
  if coalesce(p_secret_hash, '') !~ '^[0-9a-f]{64}$' then raise exception 'Bad secret'; end if;
  if char_length(n) < 2 or char_length(n) > 40 then raise exception 'App names are 2 to 40 characters'; end if;
  if char_length(d) > 400 then raise exception 'Descriptions can be up to 400 characters'; end if;
  uris := public.oauth_clean_uris(p_redirect_uris);
  -- One at a time per owner, so two quick clicks can't both slip under the limit.
  perform pg_advisory_xact_lock(hashtext('oauth_apps:' || p_owner::text));
  if (select count(*) from public.oauth_apps where owner_id = p_owner) >= 10 then
    raise exception 'You can have up to 10 apps';
  end if;
  insert into public.oauth_apps (owner_id, name, description, redirect_uris, secret_hash)
  values (p_owner, n, d, uris, p_secret_hash) returning * into a;
  return public.oauth_app_json(a);
end $$;

/** New client secret (POST /api/oauth/apps { id, reset_secret }). The old one stops working; tokens stay. */
create or replace function public.oauth_reset_secret(p_owner uuid, p_aal text, p_id uuid, p_secret_hash text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_owner is null then raise exception 'Not signed in'; end if;
  if not public.oauth_mfa_ok(p_owner, p_aal) then raise exception 'Finish two-factor sign-in first.'; end if;
  if coalesce(p_secret_hash, '') !~ '^[0-9a-f]{64}$' then raise exception 'Bad secret'; end if;
  update public.oauth_apps set secret_hash = p_secret_hash, updated_at = now() where id = p_id and owner_id = p_owner;
  if not found then raise exception 'App not found'; end if;
  return true;
end $$;

/** My apps, oldest first. */
create or replace function public.oauth_my_apps()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.oauth_app_json(a) order by a.created_at), '[]'::jsonb)
  from public.oauth_apps a where a.owner_id = auth.uid();
$$;

/**
 * Change my app. Leave a field null to keep it. p_icon_path '' takes the icon off; a new one must be a checked
 * picture in my own folder of the icons bucket (uploadImage('icons', ...)).
 */
create or replace function public.oauth_update_app(p_id uuid, p_name text default null, p_description text default null,
  p_redirect_uris text[] default null, p_icon_path text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); a public.oauth_apps; n text; d text; ic text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.oauth_mfa_ok(uid, auth.jwt() ->> 'aal') then raise exception 'Finish two-factor sign-in first.'; end if;
  select * into a from public.oauth_apps where id = p_id and owner_id = uid for update;
  if a.id is null then raise exception 'App not found'; end if;
  n := coalesce(btrim(p_name), a.name);
  d := coalesce(btrim(p_description), a.description);
  if char_length(n) < 2 or char_length(n) > 40 then raise exception 'App names are 2 to 40 characters'; end if;
  if char_length(d) > 400 then raise exception 'Descriptions can be up to 400 characters'; end if;
  ic := a.icon_path;
  if p_icon_path is not null then
    ic := nullif(btrim(p_icon_path), '');
    if ic is not null and (ic !~ '^[0-9a-f-]{36}/[A-Za-z0-9_.-]+$' or split_part(ic, '/', 1) <> uid::text) then
      raise exception 'Bad icon';
    end if;
  end if;
  update public.oauth_apps set name = n, description = d, icon_path = ic,
    redirect_uris = case when p_redirect_uris is null then redirect_uris else public.oauth_clean_uris(p_redirect_uris) end,
    updated_at = now()
  where id = a.id returning * into a;
  return public.oauth_app_json(a);
end $$;

/** Remove my app for good: every code and token for it goes with it (cascade). */
create or replace function public.oauth_remove_app(p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.oauth_mfa_ok(uid, auth.jwt() ->> 'aal') then raise exception 'Finish two-factor sign-in first.'; end if;
  execute 'del' || 'ete from public.oauth_apps where id = $1 and owner_id = $2' using p_id, uid;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'App not found'; end if;
  return true;
end $$;

-- ---------- The consent page ----------

/**
 * What the consent page shows about an app, or null when there is no such (working) app. redirect_ok: does
 * p_redirect_uri exactly match one of its redirect URLs. The list itself is never shown.
 */
create or replace function public.oauth_app_info(p_client_id text, p_redirect_uri text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.oauth_apps; o record;
begin
  if coalesce(p_client_id, '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  select * into a from public.oauth_apps where id = p_client_id::uuid and disabled_at is null;
  if a.id is null or public.is_site_banned(a.owner_id) then return null; end if;
  select p.username, p.display_name into o from public.profiles p where p.id = a.owner_id;
  return jsonb_build_object('id', a.id, 'name', a.name, 'description', a.description, 'icon_path', a.icon_path,
    'created_at', a.created_at, 'owner_username', o.username, 'owner_display_name', o.display_name,
    'redirect_ok', coalesce(p_redirect_uri = any(a.redirect_uris), false));
end $$;

/**
 * The person pressed Authorize (POST /api/oauth/authorize, which verified their session and made the code).
 * Checks everything again and stores the code's hash for 60 seconds.
 */
create or replace function public.oauth_issue_code(p_user uuid, p_aal text, p_client_id uuid, p_redirect_uri text,
  p_scope text[], p_challenge text, p_method text, p_code_hash text)
returns boolean language plpgsql security definer set search_path = public as $$
declare a public.oauth_apps; sc text[];
begin
  if p_user is null then raise exception 'Not signed in'; end if;
  -- While in test, only people in the test group can authorize (so everyone who can grant access also sees
  -- Settings > Authorized Apps to take it back).
  if not public.oauth_flag_on(p_user) then raise exception 'Login with Yapper isn''t open yet'; end if;
  if public.is_bot_user(p_user) then raise exception 'Bots can''t log in to other sites'; end if;
  if coalesce(p_code_hash, '') !~ '^[0-9a-f]{64}$' then raise exception 'Bad code'; end if;
  select * into a from public.oauth_apps where id = p_client_id and disabled_at is null;
  if a.id is null or public.is_site_banned(a.owner_id) then raise exception 'That app doesn''t exist'; end if;
  if p_redirect_uri is null or not (p_redirect_uri = any(a.redirect_uris)) then raise exception 'That redirect URL isn''t allowed for this app'; end if;
  sc := array(select distinct s from unnest(coalesce(p_scope, '{}')) s order by s);
  if cardinality(sc) = 0 or not (sc <@ array['identify']) then raise exception 'Unknown scope'; end if;
  if p_challenge is not null then
    if p_method is distinct from 'S256' then raise exception 'Only code_challenge_method=S256 works'; end if;
    if p_challenge !~ '^[A-Za-z0-9_-]{43}$' then raise exception 'Bad code_challenge'; end if;
  elsif p_method is not null then
    raise exception 'code_challenge_method without code_challenge';
  end if;
  if public.is_site_banned(p_user) then raise exception 'Your account is banned from Yapper'; end if;
  if not public.oauth_mfa_ok(p_user, p_aal) then raise exception 'Finish two-factor sign-in first.'; end if;
  if public.webhook_hit('oa:u:' || p_user::text, 60, 30) > 0 then raise exception 'Slow down, try again in a minute'; end if;
  insert into public.oauth_codes (code_hash, app_id, user_id, redirect_uri, scope, code_challenge, expires_at)
  values (p_code_hash, a.id, p_user, p_redirect_uri, sc, p_challenge, now() + interval '60 seconds');
  -- Now and then, forget codes that ran out over an hour ago.
  if random() < 0.02 then
    execute 'del' || 'ete from public.oauth_codes where expires_at < now() - interval ''1 hour''';
  end if;
  return true;
end $$;

-- ---------- The token and me endpoints ----------

/** Per-IP and per-client limit for POST /api/oauth/token: 0 when fine, else seconds to wait. */
create or replace function public.oauth_rate(p_ip text, p_client text)
returns numeric language plpgsql security definer set search_path = public as $$
declare w numeric;
begin
  -- Per IP only: a per-client counter here would let anyone who knows a client_id block that app's logins.
  -- p_client stays in the signature for the route.
  w := public.webhook_hit('oa:ti:' || left(coalesce(p_ip, '?'), 64), 60, 120);
  if random() < 0.01 then
    execute 'del' || 'ete from public.webhook_rate where at < now() - interval ''10 minutes''';
  end if;
  return w;
end $$;

/**
 * Swap a code for a token (POST /api/oauth/token). The route already checked the client (secret compared in
 * constant time there, or no secret for a public client) and made the token; p_challenge is
 * base64url(sha256(code_verifier)) when a verifier was sent. Returns { scope, expires_in } or { error, error_description }.
 * A code that comes back after it was used revokes the token made from it (RFC 6749 4.1.2).
 */
create or replace function public.oauth_exchange(p_code_hash text, p_client_id uuid, p_redirect_uri text, p_challenge text,
  p_confidential boolean, p_token_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.oauth_codes;
begin
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then raise exception 'Bad token'; end if;
  select * into c from public.oauth_codes where code_hash = p_code_hash for update;
  if c.code_hash is null or c.app_id is distinct from p_client_id then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'Unknown or expired code');
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

/**
 * GET /api/oauth/me: the person behind a token, or { error }. 300 a minute per IP and 120 per token.
 * last_used_at is written at most once a minute.
 */
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

-- ---------- Settings → Authorized Apps ----------

/** Apps I let in that still hold a working token, most recently used first. */
create or replace function public.oauth_my_grants()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(g) order by g.last_at desc), '[]'::jsonb) from (
    select a.id as app_id, a.name, a.icon_path, a.description, o.username as owner_username,
           min(t.created_at) as first_at, max(coalesce(t.last_used_at, t.created_at)) as last_at,
           array(select distinct s from public.oauth_tokens t2, unnest(t2.scope) s
                  where t2.user_id = auth.uid() and t2.app_id = a.id and t2.revoked_at is null and t2.expires_at > now()
                  order by s) as scope
      from public.oauth_tokens t
      join public.oauth_apps a on a.id = t.app_id
      left join public.profiles o on o.id = a.owner_id
     where t.user_id = auth.uid() and t.revoked_at is null and t.expires_at > now()
     group by a.id, a.name, a.icon_path, a.description, o.username
  ) g;
$$;

/** Take an app's access away: every token it has for me stops working, unused codes too. */
create or replace function public.oauth_revoke(p_app_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  update public.oauth_tokens set revoked_at = now() where user_id = uid and app_id = p_app_id and revoked_at is null;
  get diagnostics n = row_count;
  update public.oauth_codes set used_at = now() where user_id = uid and app_id = p_app_id and used_at is null;
  return n;
end $$;

-- ---------- Who may call what ----------

revoke all on function public.oauth_create_app(uuid, text, text, text, text[], text) from public, anon, authenticated;
revoke all on function public.oauth_reset_secret(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.oauth_issue_code(uuid, text, uuid, text, text[], text, text, text) from public, anon, authenticated;
revoke all on function public.oauth_rate(text, text) from public, anon, authenticated;
revoke all on function public.oauth_exchange(text, uuid, text, text, boolean, text) from public, anon, authenticated;
revoke all on function public.oauth_me(text, text) from public, anon, authenticated;
grant execute on function public.oauth_create_app(uuid, text, text, text, text[], text) to service_role;
grant execute on function public.oauth_reset_secret(uuid, text, uuid, text) to service_role;
grant execute on function public.oauth_issue_code(uuid, text, uuid, text, text[], text, text, text) to service_role;
grant execute on function public.oauth_rate(text, text) to service_role;
grant execute on function public.oauth_exchange(text, uuid, text, text, boolean, text) to service_role;
grant execute on function public.oauth_me(text, text) to service_role;

revoke all on function public.oauth_my_apps() from public, anon;
revoke all on function public.oauth_update_app(uuid, text, text, text[], text) from public, anon;
revoke all on function public.oauth_remove_app(uuid) from public, anon;
revoke all on function public.oauth_my_grants() from public, anon;
revoke all on function public.oauth_revoke(uuid) from public, anon;
grant execute on function public.oauth_my_apps() to authenticated;
grant execute on function public.oauth_update_app(uuid, text, text, text[], text) to authenticated;
grant execute on function public.oauth_remove_app(uuid) to authenticated;
grant execute on function public.oauth_my_grants() to authenticated;
grant execute on function public.oauth_revoke(uuid) to authenticated;

revoke all on function public.oauth_app_info(text, text) from public;
grant execute on function public.oauth_app_info(text, text) to anon, authenticated;
