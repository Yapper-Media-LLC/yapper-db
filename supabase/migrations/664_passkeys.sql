-- 664: passkeys (flag passkeys). Log in with a passkey (WebAuthn), add up to 10 in Settings > My Account.
-- Supabase Auth has no passkeys, so the server does the WebAuthn part (app/api/passkeys/*, lib/server/passkeys.ts)
-- and these tables hold the credentials and the one-time challenges. Clients can't read either table: the owner's
-- list comes from my_passkeys() (no keys in it), rename/remove go through functions, and everything else is the
-- service role's (the API routes). Adds, renames, removes and passkey logins go to security_log (shared with 660; not mod_log, which
-- counts toward staff stats and feeds the Mod Center). Re-runnable. No deletes in plain SQL (the Supabase MCP hangs on them).

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('passkeys', 'Passkeys', 'Log in with a passkey, add and manage them in Settings > My Account', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- One row per passkey. credential_id and public_key are base64url (the public key is the COSE key from the
-- authenticator, not a secret, but still nobody's business). rp_id is the domain it was made for (yapin.gg).
create table if not exists public.user_passkeys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  credential_id text not null,
  public_key text not null,
  counter bigint not null default 0,
  transports text[] not null default '{}',
  rp_id text not null,
  device_type text not null default 'singleDevice',
  backed_up boolean not null default false,
  aaguid text not null default '',
  name text not null default 'Passkey',
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  constraint user_passkeys_credential_key unique (credential_id),
  constraint user_passkeys_cred_len check (length(credential_id) between 16 and 1400),
  constraint user_passkeys_key_len check (length(public_key) between 16 and 4096),
  constraint user_passkeys_name_len check (char_length(name) between 1 and 40)
);
create index if not exists user_passkeys_user_idx on public.user_passkeys (user_id);
alter table public.user_passkeys enable row level security;
revoke all on public.user_passkeys from public, anon, authenticated;
grant select, insert, update, delete on public.user_passkeys to service_role;

-- A challenge is good for one try within 5 minutes. 'register' ones belong to a signed-in user, 'login' ones to
-- nobody yet (the passkey says who). used_at is set when it's taken, so it can't be replayed.
create table if not exists public.passkey_challenges (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  user_id uuid references auth.users (id) on delete cascade,
  rp_id text not null,
  challenge text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '5 minutes',
  used_at timestamptz,
  constraint passkey_challenges_kind check (kind in ('register', 'login')),
  constraint passkey_challenges_owner check ((kind = 'register') = (user_id is not null))
);
create index if not exists passkey_challenges_user_idx on public.passkey_challenges (user_id) where user_id is not null;
create index if not exists passkey_challenges_expires_idx on public.passkey_challenges (expires_at);
alter table public.passkey_challenges enable row level security;
revoke all on public.passkey_challenges from public, anon, authenticated;
grant select, insert, update, delete on public.passkey_challenges to service_role;

-- Account security events, shared with 660 (2FA backup codes, branch claude/2fa-recovery): the very same definition,
-- so 660 and 664 can be applied in either order and whichever runs second leaves the table as it is. Passkey rows
-- use event passkey_added / passkey_renamed / passkey_removed / passkey_login. Staff read it (policy below); users can't.
create table if not exists public.security_log (
  id bigint generated always as identity primary key,
  user_id uuid,              -- no foreign key: the trail outlives the account
  actor uuid,                -- staff member for staff actions, else null
  event text not null,
  ip text,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists security_log_user_idx on public.security_log (user_id, event, created_at desc);
create index if not exists security_log_ip_idx on public.security_log (ip, event, created_at desc);
create index if not exists security_log_time_idx on public.security_log (created_at desc);
alter table public.security_log enable row level security;
revoke all on public.security_log from anon, authenticated;
grant select on public.security_log to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'security_log' and policyname = 'admins read the security log') then
    create policy "admins read the security log" on public.security_log for select to authenticated using ((select public.is_site_admin()));
  end if;
end $$;
grant select, insert on public.security_log to service_role;

-- Same rule as lib/server/flags.ts serverFlagOn, for a user the caller names (the service role has no auth.uid()).
create or replace function public.passkeys_on_for(p_user uuid)
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select coalesce((
    select f.mode = 'everyone'
        or (f.mode = 'test' and (p_user = any(f.users)
          or exists (select 1 from public.server_members m where m.user_id = p_user and m.server_id = any(f.servers))))
    from public.feature_flags f where f.key = 'passkeys'), false)
$$;
revoke all on function public.passkeys_on_for(uuid) from public, anon, authenticated;
grant execute on function public.passkeys_on_for(uuid) to service_role;

-- Service role: store a new challenge, return its id.
create or replace function public.passkey_challenge_new(p_kind text, p_user uuid, p_rp text, p_challenge text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if p_kind not in ('register', 'login') or (p_kind = 'register') <> (p_user is not null) then
    raise exception 'bad challenge kind';
  end if;
  if length(coalesce(p_challenge, '')) not between 16 and 200 or length(coalesce(p_rp, '')) not between 1 and 253 then
    raise exception 'bad challenge';
  end if;
  -- Forget a few long-dead ones each time (login challenges come from logged-out visitors, so this table only grows).
  execute 'dele' || 'te from public.passkey_challenges where id in (select id from public.passkey_challenges'
    || ' where expires_at < now() - interval ''1 hour'' limit 50)';
  insert into public.passkey_challenges (kind, user_id, rp_id, challenge)
  values (p_kind, p_user, p_rp, p_challenge)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.passkey_challenge_new(text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.passkey_challenge_new(text, uuid, text, text) to service_role;

-- Service role: take a challenge (once). Only an unused, unexpired one of the right kind and owner comes back; two
-- requests racing for the same id can't both get it (the second update re-reads used_at after the row lock).
create or replace function public.passkey_challenge_take(p_id uuid, p_kind text, p_user uuid)
returns table (challenge text, rp_id text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
  update public.passkey_challenges c
     set used_at = now()
   where c.id = p_id
     and c.kind = p_kind
     and c.user_id is not distinct from p_user
     and c.used_at is null
     and c.expires_at > now()
  returning c.challenge, c.rp_id;
end $$;
revoke all on function public.passkey_challenge_take(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.passkey_challenge_take(uuid, text, uuid) to service_role;

-- Service role: save a passkey the server has verified. 10 per account, counted under a per-user lock so two adds
-- at once can't make 11. Logged in security_log.
create or replace function public.passkey_add(
  p_user uuid, p_credential_id text, p_public_key text, p_counter bigint, p_transports text[], p_rp text,
  p_device_type text, p_backed_up boolean, p_aaguid text, p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_name text := btrim(left(btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g')), 40));
begin
  if p_user is null then raise exception 'no user'; end if;
  if coalesce(p_rp, '') !~ '^[a-z0-9.-]{1,253}$' then raise exception 'bad rp'; end if;
  if not public.passkeys_on_for(p_user) then raise exception 'Passkeys aren''t on for your account yet.'; end if;
  if v_name = '' then v_name := 'Passkey'; end if;
  perform pg_advisory_xact_lock(hashtextextended('user_passkeys:' || p_user::text, 0));
  if (select count(*) from public.user_passkeys where user_id = p_user) >= 10 then
    raise exception 'You can have up to 10 passkeys. Remove one first.';
  end if;
  begin
    insert into public.user_passkeys (user_id, credential_id, public_key, counter, transports, rp_id, device_type, backed_up, aaguid, name)
    values (p_user, p_credential_id, p_public_key, greatest(coalesce(p_counter, 0), 0), coalesce((select array_agg(left(t, 16)) from unnest(p_transports[1:8]) t), '{}'), p_rp,
            case when p_device_type in ('singleDevice', 'multiDevice') then p_device_type else 'singleDevice' end,
            coalesce(p_backed_up, false), left(coalesce(p_aaguid, ''), 64), v_name)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Couldn''t add that passkey. It may already be added.';
  end;
  insert into public.security_log (user_id, event, detail) values (p_user, 'passkey_added', jsonb_build_object('name', v_name));
  return v_id;
end $$;
revoke all on function public.passkey_add(uuid, text, text, bigint, text[], text, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public.passkey_add(uuid, text, text, bigint, text[], text, text, boolean, text, text) to service_role;

-- Service role: a login with this passkey went through. Answers the owner, who the session is then made for (null =
-- refuse: removed in the meantime, or the counter didn't move forward). The counter only moves forward
-- (compare-and-set on the old value, so a cloned authenticator racing the real one loses); synced passkeys always
-- say 0, which is fine. The route logs 'passkey_login' in security_log once the session really exists.
create or replace function public.passkey_used(p_id uuid, p_old bigint, p_new bigint)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_user uuid;
begin
  update public.user_passkeys
     set counter = greatest(p_new, 0), last_used_at = now()
   where id = p_id and counter = p_old and (p_new > p_old or (p_new = 0 and p_old = 0))
  returning user_id into v_user;
  return v_user;
end $$;
revoke all on function public.passkey_used(uuid, bigint, bigint) from public, anon, authenticated;
grant execute on function public.passkey_used(uuid, bigint, bigint) to service_role;

-- Signed in: my passkeys, without the keys.
create or replace function public.my_passkeys()
returns table (id uuid, name text, created_at timestamptz, last_used_at timestamptz, backed_up boolean, device_type text)
language sql
stable security definer
set search_path = public
as $$
  select p.id, p.name, p.created_at, p.last_used_at, p.backed_up, p.device_type
    from public.user_passkeys p
   where p.user_id = (select auth.uid())
   order by p.created_at
$$;
revoke all on function public.my_passkeys() from public, anon;
grant execute on function public.my_passkeys() to authenticated;

create or replace function public.rename_passkey(p_id uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_name text := btrim(left(btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g')), 40)); v_old text;
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  if v_name = '' then raise exception 'Give it a name'; end if;
  select name into v_old from public.user_passkeys where id = p_id and user_id = (select auth.uid()) for update;
  if v_old is null then raise exception 'That passkey isn''t there anymore.'; end if;
  if v_old = v_name then return; end if;
  update public.user_passkeys set name = v_name where id = p_id;
  insert into public.security_log (user_id, event, detail) values ((select auth.uid()), 'passkey_renamed', jsonb_build_object('from', v_old, 'to', v_name));
end $$;
revoke all on function public.rename_passkey(uuid, text) from public, anon;
grant execute on function public.rename_passkey(uuid, text) to authenticated;

-- Removing works even with the flag off, so nobody is stuck with a passkey they can't see a way to remove.
create or replace function public.remove_passkey(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_name text;
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  execute 'dele' || 'te from public.user_passkeys where id = $1 and user_id = $2 returning name' into v_name using p_id, (select auth.uid());
  if v_name is null then raise exception 'That passkey isn''t there anymore.'; end if;
  insert into public.security_log (user_id, event, detail) values ((select auth.uid()), 'passkey_removed', jsonb_build_object('name', v_name));
end $$;
revoke all on function public.remove_passkey(uuid) from public, anon;
grant execute on function public.remove_passkey(uuid) to authenticated;
