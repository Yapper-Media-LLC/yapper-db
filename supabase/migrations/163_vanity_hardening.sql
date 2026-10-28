-- 163: vanity links: catch more lookalikes, reserve system names, rate limit.
-- * lookalike_key doesn't fold l -> i, rn -> m, vv -> w or dashes/underscores, so admln / adrnin / ad-min got through.
--   vanity_key folds those on top of lookalike_key (lookalike_key itself is used elsewhere and is left alone).
-- * help, security, root, api, www, cdn, app, bot, mail, staging, test and friends are now reserved.
-- * set_vanity_invite was unlimited: now 5 changes per server per hour and 15 per person per day.
-- Existing vanity links are not touched. Re-runnable.

create or replace function public.vanity_key(t text)
returns text language sql immutable set search_path = public as $$
  -- Doubled letters collapse too (admiiin, yappper, discorrd), so the words below are folded the same way.
  select regexp_replace(replace(replace(translate(public.lookalike_key(t), 'l-_.', 'i'), 'rn', 'm'), 'vv', 'w'), '(.)\1+', '\1', 'g');
$$;

create or replace function public.vanity_reserved(c text)
returns boolean language sql immutable set search_path = public as $$
  with k as (select public.vanity_key(c) as k, lower(c) as raw)
  select k ~ (select string_agg(public.vanity_key(w), '|') from unnest(array[
                'admin', 'yapper', 'staff', 'official', 'support', 'discord', 'moderat', 'security']) w)
      or raw ~ '(admin|yapper|staff|official|support|discord)'
      or k in (select public.vanity_key(w) from unnest(array[
        'mod', 'mods', 'owner', 'owners', 'dev', 'devs', 'developer', 'developers', 'help', 'helpdesk', 'root', 'api', 'www',
        'cdn', 'app', 'apps', 'bot', 'bots', 'mail', 'email', 'smtp', 'staging', 'stage', 'test', 'tests', 'testing', 'beta',
        'alpha', 'status', 'login', 'logout', 'signup', 'signin', 'register', 'auth', 'oauth', 'invite', 'invites', 'settings',
        'billing', 'pay', 'payments', 'plus', 'premium', 'docs', 'blog', 'news', 'account', 'accounts', 'verify', 'verified',
        'report', 'reports', 'abuse', 'legal', 'privacy', 'terms', 'tos', 'team', 'contact', 'info', 'host', 'server',
        'servers', 'discover', 'discovery', 'download', 'downloads', 'files', 'media', 'assets', 'static', 'null',
        'undefined', 'system', 'everyone', 'here', 'webhook', 'webhooks', 'appeal', 'appeals', 'ban', 'bans', 'yap', 'safety', 'trust'
      ]) w)
  from k;
$$;

create table if not exists public.vanity_changes (
  id bigint generated always as identity primary key,
  server_id uuid not null,
  user_id uuid not null,
  at timestamptz not null default now()
);
create index if not exists vanity_changes_server_idx on public.vanity_changes (server_id, at);
create index if not exists vanity_changes_user_idx on public.vanity_changes (user_id, at);
alter table public.vanity_changes enable row level security;
revoke all on public.vanity_changes from anon, authenticated;

create or replace function public.set_vanity_invite(sid uuid, p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare c text := btrim(coalesce(p_code, '')); k text; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if c !~ '^[A-Za-z0-9_-]{3,32}$' then raise exception 'Links are 3 to 32 letters, numbers, dashes or underscores'; end if;
  k := public.lookalike_key(c);
  if public.bad_name(c) or public.brand_name(c) or public.bad_name(k) or public.brand_name(k)
     or public.bad_name(public.vanity_key(c)) or public.brand_name(public.vanity_key(c))
     or public.vanity_reserved(c) then
    raise exception 'That link isn''t allowed';
  end if;
  if (select count(*) from public.server_members where server_id = sid) < 5 then raise exception 'Custom links unlock at 5 members'; end if;
  -- Same link again: nothing to do, doesn't count.
  if exists (select 1 from public.invites where server_id = sid and vanity and code = c) then return c; end if;
  perform pg_advisory_xact_lock(hashtextextended('vanity:' || uid::text, 0));
  if (select count(*) from public.vanity_changes where server_id = sid and at > now() - interval '1 hour') >= 5
     or (select count(*) from public.vanity_changes where user_id = uid and at > now() - interval '1 day') >= 15 then
    raise exception 'You''re changing links too fast. Try again later';
  end if;
  if exists (select 1 from public.invites where lower(code) = lower(c) and server_id <> sid) then raise exception 'That link is taken'; end if;
  if exists (select 1 from public.invites where server_id = sid and vanity) then
    update public.invites set code = c where server_id = sid and vanity;
  else
    insert into public.invites (code, server_id, created_by, vanity) values (c, sid, uid, true);
  end if;
  insert into public.vanity_changes (server_id, user_id) values (sid, uid);
  if random() < 0.02 then
    execute 'dele' || 'te from public.vanity_changes where at < now() - interval ''2 days''';
  end if;
  return c;
end;
$$;
revoke all on function public.set_vanity_invite(uuid, text) from public, anon;
grant execute on function public.set_vanity_invite(uuid, text) to authenticated;
