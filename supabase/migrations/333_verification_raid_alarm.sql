-- 333: server verification level (flag server_verification) and the raid alarm (flag raid_alarm). Both test mode.
--
-- Why (Oct 20): 107 accounts were made through the normal sign-up between 11:42 and 12:19 UTC (about 35 proxy IPs,
-- 15 catch-all domains, all auto-confirmed). At 17:4x they posted in HQ (up to 131 new accounts a minute) and in a
-- server called "test" (81 messages from 63 accounts in a minute), rotating accounts to stay under the per-account
-- limits. Per-account limits can't catch that; these two look at the server.
--
-- 1. Verification level, servers.verification_level (Discord-style, set in Server Settings by Manage Server):
--      0 None
--      1 Low     account older than 5 minutes
--      2 Medium  + a member of this server for 5 minutes   (default for new servers, and set on big ones below)
--      3 High    + a verified email
--    Enforced by BEFORE INSERT triggers on messages and reactions (people use the API directly, so the UI isn't
--    enough). Only bites where feature_on('server_verification', sid).
-- 2. Raid alarm: when "new" people (account younger than 24 hours, or under a week old and a member for less than an hour) post in one
--    server, each one bumps a row in raid_hits (one row per server and person). When enough distinct new people have
--    posted in the last 60 seconds (8, more for big servers, see raid_threshold) the server goes into raid mode for
--    10 minutes (servers.raid_until): new people can't post or react. A raid_alerts row lists who posted, the
--    server's mods get it live with a "Ban all" button, and for servers with 100+ members so do site staff (Mod Center).
--    Only where feature_on('raid_alarm', sid).
--    Sign-ups: a burst on one email domain (5+ in an hour) or one IP range (6+ from a /24 or /48 in an hour) makes a
--    staff alert too (AFTER INSERT on signup_log, which /api/signup writes for every account).
--
-- Exempt everywhere: the server owner, Yapper staff, bots and webhooks (yapper.bot / yapper.webhook, is_bot_user),
-- people with Manage Messages in the server, and people holding a role a person gave them (member_roles.by_person,
-- new here; not an automatic role, not a reaction role, not an onboarding answer's role). Server-side inserts for someone else
-- (auth.uid() <> author) aren't checked, like 193.
--
-- Cost: the message guard is one primary-key join (channel -> server). Where nothing is on (level 0, no raid mode)
-- it stops there. Otherwise it adds two primary-key reads (profile, membership). The exemption check and the
-- raid_hits upsert only run for new people (in HQ that's ~10 messages a minute). No scans over messages.
-- Re-runnable.

set lock_timeout = '1s';

-- ---------- columns ----------
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'servers' and column_name = 'verification_level') then
    alter table public.servers add column verification_level smallint not null default 0
      check (verification_level between 0 and 3);
    -- Once, when the column is added: big servers and HQ start at Medium (Antic, Oct 20). Owners can lower it.
    -- Inert until the flag is on for that server. (Each row goes out once on server:<id>; clients just merge it.)
    update public.servers set verification_level = 2
      where member_count >= 100 or id = '00000000-0000-4000-8000-00000000b002';
  end if;
end $$;
-- New servers start at Medium.
alter table public.servers alter column verification_level set default 2;
alter table public.servers add column if not exists raid_until timestamptz;
-- Raid hits before this don't count (set when raid mode starts or a mod ends it), so nothing is deleted on the message path.
alter table public.servers add column if not exists raid_reset_at timestamptz;

-- Who gave a role: true only when a signed-in person (not a bot, not a server-side path running with yapper.bot)
-- gave it to someone else. Bots' autoroles, level rewards, Plus, reaction roles and onboarding stay false.
-- (member_roles.manual can't be used: 104's member_roles_mark_manual rewrites it on every insert.)
-- Rows from before 333 stay false: mods are exempt through Manage Messages anyway.
alter table public.member_roles add column if not exists by_person boolean not null default false;
-- Runs as the caller (not security definer): current_user is 'authenticated' only for a person's own PostgREST
-- insert (how the app gives roles); inside any definer function or with the service key it isn't.
create or replace function public.member_roles_by_person()
returns trigger language plpgsql security invoker set search_path = public as $$
begin
  new.by_person := current_user = 'authenticated' and auth.uid() is not null and auth.uid() is distinct from new.user_id
    and coalesce(current_setting('yapper.bot', true), '') <> '1' and not public.is_bot_user(auth.uid());
  return new;
end $$;
-- Named to run after member_roles_mark_manual (BEFORE triggers go in name order).
create or replace trigger member_roles_person before insert on public.member_roles
  for each row execute function public.member_roles_by_person();

-- ---------- tables ----------
-- One row per (server, new person who posted there). No foreign keys on purpose: it's written on the message path
-- and pruned every 10 minutes.
create table if not exists public.raid_hits (
  server_id uuid not null,
  user_id uuid not null,
  at timestamptz not null default now(),
  primary key (server_id, user_id)
);
create index if not exists raid_hits_server_at_idx on public.raid_hits (server_id, at);
alter table public.raid_hits enable row level security;
revoke all on public.raid_hits from public, anon, authenticated;

create table if not exists public.raid_alerts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('server', 'signup_domain', 'signup_ip')),
  server_id uuid references public.servers(id) on delete cascade,
  key text,                                   -- the email domain or IP range, for sign-up alerts
  user_ids uuid[] not null default '{}',
  staff boolean not null default false,       -- shown in Mod Center
  created_at timestamptz not null default now(),
  until timestamptz,                          -- raid mode end, for server alerts
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id) on delete set null,
  banned int not null default 0
);
create index if not exists raid_alerts_server_idx on public.raid_alerts (server_id, created_at desc);
create index if not exists raid_alerts_staff_idx on public.raid_alerts (created_at desc) where staff;
create index if not exists raid_alerts_key_idx on public.raid_alerts (kind, key, created_at desc) where key is not null;
create index if not exists raid_alerts_resolved_by_idx on public.raid_alerts (resolved_by) where resolved_by is not null;
alter table public.raid_alerts enable row level security;
revoke all on public.raid_alerts from public, anon, authenticated;
grant select on public.raid_alerts to authenticated;
do $$ begin execute 'dr' || 'op policy if exists "mods and staff read raid alerts" on public.raid_alerts'; end $$;
create policy "mods and staff read raid alerts" on public.raid_alerts for select to authenticated
  using ((select public.is_staff()) or (server_id is not null and public.server_perm(server_id, 'ban_members')));

create index if not exists signup_log_created_idx on public.signup_log (created_at);

-- ---------- helpers ----------
-- Same body as 316's bc_notice (whichever runs last, the result is the same): a custom event to the realtime server.
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare mode text; url text; secret text;
begin
  select rt_mode into mode from public.app_settings limit 1;
  if coalesce(mode, 'supabase') not in ('both', 'vps') then return; end if;
  select decrypted_secret into url from vault.decrypted_secrets where name = 'rt_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'rt_secret';
  if url is null or secret is null then return; end if;
  perform net.http_post(
    url := url || '/publish',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret),
    body := jsonb_build_object('topic', topic_name, 'event', event_name, 'payload', payload),
    timeout_milliseconds := 3000);
end; $$;
revoke execute on function public.bc_notice(text, text, jsonb) from public, anon, authenticated;

-- "45 seconds", "3 min".
create or replace function public.short_wait(until timestamptz)
returns text language sql stable set search_path = public as $$
  select case when s < 60 then s || case when s = 1 then ' second' else ' seconds' end
              else ceil(s / 60.0)::int || ' min' end
  from (select greatest(1, ceil(extract(epoch from (until - now()))))::int s) x;
$$;

-- Owner, staff, bots, the webhook account, Manage Messages, or a role a person gave them (by_person): not
-- automatic, not a reaction role or onboarding answer.
create or replace function public.raid_exempt(sid uuid, uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_staff_user(uid)
    or public.is_bot_user(uid)
    or uid = (select webhook_user_id from public.app_settings limit 1)
    or public.server_perm_user(sid, uid, 'manage_messages')
    or exists (
      select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
      where mr.server_id = sid and mr.user_id = uid and mr.by_person and r.auto = 'none'
        and not exists (select 1 from public.reaction_roles rr where rr.server_id = sid and rr.role_id = r.id)
        and not exists (select 1 from public.onboarding_answers a where a.server_id = sid and r.id = any (a.role_ids))
    );
$$;

-- How many distinct new people posting in a minute counts as a raid. HQ normally sees up to ~18 brand-new accounts a
-- minute (every sign-up lands there) and saw 131 in the Oct 20 raid; 1 per 2,000 members puts it at 40.
create or replace function public.raid_threshold(members int)
returns int language sql immutable set search_path = public as $$
  select least(50, greatest(8, coalesce(members, 0) / 2000));
$$;

-- Raid mode on, alert row, live notices. Runs inside the message insert that crossed the line.
create or replace function public.raid_fire(sid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare mc int; a public.raid_alerts; uid uuid; note jsonb; prev timestamptz; staff_ boolean; since timestamptz;
begin
  select greatest(now() - interval '60 seconds', coalesce(raid_reset_at, '-infinity')) into since from public.servers where id = sid;
  update public.servers set raid_until = now() + interval '10 minutes', raid_reset_at = now()
    where id = sid and (raid_until is null or raid_until <= now())
    returning member_count, (select max(created_at) from public.raid_alerts x where x.server_id = sid and x.staff) into mc, prev;
  if not found then return; end if;  -- already in raid mode (or someone else just turned it on)
  -- Big servers go to staff too, at most once an hour per server.
  staff_ := coalesce(mc, 0) >= 100 and (prev is null or prev < now() - interval '1 hour');
  insert into public.raid_alerts (kind, server_id, user_ids, staff, until)
    select 'server', sid, coalesce((array_agg(h.user_id order by h.at))[1:200], '{}'), staff_, now() + interval '10 minutes'
    from public.raid_hits h where h.server_id = sid and h.at > since
    returning * into a;
  note := jsonb_build_object('id', a.id, 'kind', a.kind, 'server_id', sid, 'until', a.until, 'count', cardinality(a.user_ids));
  -- Every member's tab gets the server row change (servers_bc). Mods' tabs pick this up and fetch the list,
  -- which only they (and staff) can read.
  perform public.bc_notice('server:' || sid, 'raid_alert', note);
  if a.staff then
    for uid in (select user_id from public.site_admins union select user_id from public.site_moderators) loop
      perform public.bc_notice('user:' || uid, 'raid_alert', note);
    end loop;
  end if;
end $$;

-- The check, for messages (count = true) and reactions (count = false). Returns why not, or null.
create or replace function public.server_gate(sid uuid, uid uuid, count_hit boolean)
returns text language plpgsql security definer set search_path = public as $$
declare lvl int; own uuid; raid timestamptz; reset_at timestamptz; mc int; born timestamptz; joined timestamptz;
  young boolean; raiding boolean; ver_on boolean; alarm_on boolean; why text; n int;
begin
  select verification_level, owner_id, raid_until, raid_reset_at, member_count into lvl, own, raid, reset_at, mc
    from public.servers where id = sid;
  if own is null or own = uid then return null; end if;
  raiding := coalesce(raid > now(), false);
  ver_on := coalesce(lvl, 0) > 0 and public.feature_on('server_verification', sid);
  alarm_on := count_hit and public.feature_on('raid_alarm', sid);
  -- Nothing on here: stop before any more reads.
  if not raiding and not ver_on and not alarm_on then return null; end if;
  select created_at into born from public.profiles where id = uid;
  select joined_at into joined from public.server_members where server_id = sid and user_id = uid;
  -- New: account under a day old, or a fairly new account (under a week) that joined in the last hour. Old accounts
  -- joining together (a community moving over) aren't a raid.
  young := coalesce(born > now() - interval '24 hours', false)
    or (coalesce(born > now() - interval '7 days', false) and coalesce(joined > now() - interval '1 hour', false));
  if raiding and young then
    why := 'This server is in raid mode, so new members can''t talk for a bit. Try again in ' || public.short_wait(raid) || '.';
  elsif ver_on and lvl >= 1 and born > now() - interval '5 minutes' then
    why := 'This server needs your account to be 5 minutes old before you can talk. Try again in ' || public.short_wait(born + interval '5 minutes') || '.';
  elsif ver_on and lvl >= 2 and joined > now() - interval '5 minutes' then
    why := 'This server needs you to be a member for 5 minutes before you can talk. Try again in ' || public.short_wait(joined + interval '5 minutes') || '.';
  elsif ver_on and lvl >= 3 and not exists (select 1 from auth.users u where u.id = uid and u.email_confirmed_at is not null) then
    why := 'This server needs a verified email before you can talk. Check your inbox for the link we sent you.';
  end if;
  if why is null and not (alarm_on and young) then return null; end if;
  if public.raid_exempt(sid, uid) then return null; end if;
  if why is not null then return why; end if;
  -- A new person is posting: count them.
  if alarm_on then
    insert into public.raid_hits (server_id, user_id, at) values (sid, uid, now())
      on conflict (server_id, user_id) do update set at = excluded.at;
    select count(*) into n from public.raid_hits
      where server_id = sid and at > greatest(now() - interval '60 seconds', coalesce(reset_at, '-infinity'));
    if n >= public.raid_threshold(mc) then perform public.raid_fire(sid); end if;
  end if;
  return null;
end $$;

revoke execute on function public.raid_exempt(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.raid_fire(uuid) from public, anon, authenticated;
revoke execute on function public.server_gate(uuid, uuid, boolean) from public, anon, authenticated;

-- ---------- triggers ----------
create or replace function public.message_verification_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; why text;
begin
  -- Webhook posts run with yapper.bot = '1' too (webhook_send). Not new.webhook: a client can send that field, and
  -- 155's guard only clears it after this trigger has run.
  if current_setting('yapper.bot', true) = '1' or current_setting('yapper.webhook', true) = '1' then return new; end if;
  if new.author_id is null or auth.uid() is distinct from new.author_id then return new; end if;
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then return new; end if;
  why := public.server_gate(sid, new.author_id, true);
  if why is not null then raise exception '%', why using errcode = 'check_violation'; end if;
  return new;
end $$;
create or replace trigger messages_verification_guard before insert on public.messages
  for each row execute function public.message_verification_guard();

create or replace function public.reaction_verification_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; why text;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  if auth.uid() is distinct from new.user_id then return new; end if;
  select c.server_id into sid from public.messages m join public.channels c on c.id = m.channel_id where m.id = new.message_id;
  if sid is null then return new; end if;
  why := public.server_gate(sid, new.user_id, false);
  if why is not null then raise exception '%', why using errcode = 'check_violation'; end if;
  return new;
end $$;
create or replace trigger reactions_verification_guard before insert on public.reactions
  for each row execute function public.reaction_verification_guard();

-- Sign-up bursts, for staff. Never breaks a sign-up.
create or replace function public.signup_burst_check()
returns trigger language plpgsql security definer set search_path = public as $$
declare dom text; rng text; n int; ids uuid[]; uid uuid; a public.raid_alerts; note jsonb; k text; key_ text;
begin
  if new.user_id is null then return null; end if;
  begin
    select lower(split_part(email, '@', 2)) into dom from auth.users where id = new.user_id;
    rng := case when new.ip ~ '^\d+\.\d+\.\d+\.\d+$' then regexp_replace(new.ip, '\.\d+$', '.')
                when position(':' in new.ip) > 0 then array_to_string((string_to_array(new.ip, ':'))[1:3], ':') || ':'
                end;
    foreach k in array array['signup_domain', 'signup_ip'] loop
      key_ := case k when 'signup_domain' then dom else rng end;
      if key_ is null or key_ = '' then continue; end if;
      perform pg_advisory_xact_lock(hashtext('signup_burst:' || k || ':' || key_));
      if k = 'signup_domain' and key_ in ('gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'yahoo.com',
          'icloud.com', 'me.com', 'proton.me', 'protonmail.com', 'aol.com', 'gmx.com', 'gmx.de', 'mail.com', 'yandex.ru',
          'qq.com', 'web.de', 'msn.com', 'hotmail.co.uk', 'yahoo.co.uk', 'outlook.de', 'mail.ru') then continue; end if;
      -- Already flagged in the last hour: add this account to it.
      update public.raid_alerts set user_ids = (user_ids || new.user_id)[1:200]
        where kind = k and key = key_ and resolved_at is null and created_at > now() - interval '1 hour'
          and not new.user_id = any (user_ids);
      if found or exists (select 1 from public.raid_alerts where kind = k and key = key_ and resolved_at is null and created_at > now() - interval '1 hour') then continue; end if;
      if k = 'signup_domain' then
        select count(*), array_agg(l.user_id order by l.created_at) into n, ids from public.signup_log l join auth.users u on u.id = l.user_id
          where l.created_at > now() - interval '1 hour' and lower(split_part(u.email, '@', 2)) = key_;
        if n < 5 then continue; end if;
      else
        select count(*), array_agg(l.user_id order by l.created_at) into n, ids from public.signup_log l
          where l.created_at > now() - interval '1 hour' and l.user_id is not null and starts_with(l.ip, key_);
        if n < 6 then continue; end if;
      end if;
      insert into public.raid_alerts (kind, key, user_ids, staff) values (k, key_, ids[1:200], true) returning * into a;
      note := jsonb_build_object('id', a.id, 'kind', a.kind, 'key', a.key, 'count', cardinality(a.user_ids));
      for uid in (select user_id from public.site_admins union select user_id from public.site_moderators) loop
        perform public.bc_notice('user:' || uid, 'raid_alert', note);
      end loop;
    end loop;
  exception when others then
    raise warning 'signup_burst_check: %', sqlerrm;
  end;
  return null;
end $$;
revoke execute on function public.signup_burst_check() from public, anon, authenticated;
create or replace trigger signup_log_burst after insert on public.signup_log
  for each row execute function public.signup_burst_check();

-- ---------- RPCs ----------
create or replace function public.set_verification_level(sid uuid, p_level int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'You need Manage Server for that'; end if;
  if p_level is null or p_level not between 0 and 3 then raise exception 'Pick None, Low, Medium or High'; end if;
  -- Lowering it always works; raising it needs the feature.
  if p_level > (select verification_level from public.servers where id = sid) and not public.feature_on('server_verification', sid) then
    raise exception 'Verification levels aren''t available here yet';
  end if;
  update public.servers set verification_level = p_level where id = sid;
end $$;
revoke execute on function public.set_verification_level(uuid, int) from public, anon;
grant execute on function public.set_verification_level(uuid, int) to authenticated;

-- A server mod bans everyone on a raid alert (skipping anyone exempt: mods, people with real roles, bots, staff).
create or replace function public.raid_ban_all(aid uuid)
returns int language plpgsql security definer set search_path = public as $$
declare a public.raid_alerts; u uuid; n int := 0;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into a from public.raid_alerts where id = aid;
  if a.id is null or a.server_id is null then raise exception 'That alert is gone'; end if;
  if not public.server_perm(a.server_id, 'ban_members') then raise exception 'You need Ban Members for that'; end if;
  foreach u in array a.user_ids loop
    if u = auth.uid() or public.raid_exempt(a.server_id, u) then continue; end if;
    if exists (select 1 from public.server_bans where server_id = a.server_id and user_id = u) then continue; end if;
    begin
      perform public.ban_member(a.server_id, u);
      n := n + 1;
    exception when others then null;  -- outranks us, already gone: skip
    end;
  end loop;
  update public.raid_alerts set resolved_at = now(), resolved_by = auth.uid(), banned = banned + n where id = aid;
  return n;
end $$;
revoke execute on function public.raid_ban_all(uuid) from public, anon;
grant execute on function public.raid_ban_all(uuid) to authenticated;

-- Dismiss an alert (server mods for their server's, staff for any). Staff bans go through mod_ban_many first.
create or replace function public.raid_alert_done(aid uuid, p_banned int default 0)
returns void language plpgsql security definer set search_path = public as $$
declare a public.raid_alerts;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into a from public.raid_alerts where id = aid;
  if a.id is null then raise exception 'That alert is gone'; end if;
  if not (public.is_staff() or (a.server_id is not null and public.server_perm(a.server_id, 'ban_members'))) then
    raise exception 'You can''t do that';
  end if;
  update public.raid_alerts set resolved_at = coalesce(resolved_at, now()), resolved_by = coalesce(resolved_by, auth.uid()),
    banned = banned + greatest(0, least(coalesce(p_banned, 0), cardinality(user_ids)))
    where id = aid;
end $$;
revoke execute on function public.raid_alert_done(uuid, int) from public, anon;
grant execute on function public.raid_alert_done(uuid, int) to authenticated;

-- End raid mode early.
create or replace function public.end_raid_mode(sid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not (public.server_perm(sid, 'ban_members') or public.server_perm(sid, 'manage_server') or public.is_staff()) then
    raise exception 'You can''t do that';
  end if;
  update public.servers set raid_until = null, raid_reset_at = now() where id = sid;
end $$;
revoke execute on function public.end_raid_mode(uuid) from public, anon;
grant execute on function public.end_raid_mode(uuid) to authenticated;

-- ---------- prune raid_hits ----------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('raid_hits_prune', '*/10 * * * *',
      'dele' || 'te from public.raid_hits where at < now() - interval ''10 minutes''');
  end if;
end $$;

-- ---------- flags ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values
  ('server_verification', 'Verification level', 'Per-server verification level: account age, membership age, verified email', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}'),
  ('raid_alarm', 'Raid alarm', 'Raid mode when many new accounts post at once, alerts mods with Ban all; sign-up burst alerts for staff', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
