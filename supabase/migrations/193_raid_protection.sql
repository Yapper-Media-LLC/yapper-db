-- 193: raid protection (flag raid_protection, test mode): a new account rule per server.
--
-- Context: a server got raided by brand-new accounts. Lockdown already exists (set_server_lock, server_locked,
-- auto_lock_on_raid); the app now puts it in the server menu and shows a banner in chat (no SQL needed).
--
-- New account rule: servers.new_account_minutes (null = off; 10, 60, 1440 or 10080) and new_account_mode:
--   * 'join': join_server / join_public_server refuse accounts younger than that;
--   * 'chat': they can join and react, but posting a message is refused until the account is old enough.
-- Set through set_new_account_rule (Manage Server). Turning it on needs feature_on('raid_protection', sid);
-- turning it off never does. Enforcement runs whenever a value is set, so it only bites where the flag was on.
-- Exempt: Yapper staff (joins and posts), people with Manage Messages in that server (posts), bots (posts run
-- with yapper.bot = '1'; bots are added through bot_add_to_server, which this doesn't touch).
--
-- Functions that put a joining user into server_members (checked Oct 17):
--   join_server(text)          invite links           patched here
--   join_public_server(uuid)   Discovery              patched here
--   join_default_server()      signup HQ auto-join    left alone (a new account must always land in HQ)
--   bot_add_to_server          bots                   left alone
--   create_server, create_server_from_template, import_discord_server: the owner joining their own new server.
-- Chat mode: message_raid_guard (BEFORE INSERT on messages) is patched to call new_account_chat_check only for
-- accounts younger than 7 days (the longest option), so older accounts pay nothing; for young ones it's one
-- primary-key lookup of the channel's server.
--
-- Live bodies are patched in place (pg_get_functiondef + replace); each patch fails loudly if its target text
-- isn't there and is skipped once applied (marker 193:). Re-runnable.

-- ---------- columns ----------
alter table public.servers add column if not exists new_account_minutes int
  check (new_account_minutes in (10, 60, 1440, 10080));
alter table public.servers add column if not exists new_account_mode text not null default 'join'
  check (new_account_mode in ('join', 'chat'));

-- ---------- helpers ----------
create or replace function public.new_account_label(mins int)
returns text language sql immutable set search_path = public as $$
  select case mins when 10 then '10 minutes' when 60 then '1 hour' when 1440 then '1 day' when 10080 then '7 days'
    else mins || ' minutes' end;
$$;

-- How long until then, short: "42 min", "5 hours", "3 days".
create or replace function public.wait_label(until timestamptz)
returns text language sql stable set search_path = public as $$
  select case
    when m < 60 then m || ' min'
    when m < 2880 then ceil(m / 60.0)::int || case when ceil(m / 60.0) = 1 then ' hour' else ' hours' end
    else ceil(m / 1440.0)::int || ' days' end
  from (select greatest(1, ceil(extract(epoch from (until - now())) / 60))::int m) x;
$$;

-- Join mode: called by the join functions (not for staff) right before the member row goes in.
create or replace function public.new_account_join_check(sid uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare age_min int; amode text; born timestamptz;
begin
  select new_account_minutes, new_account_mode into age_min, amode from public.servers where id = sid;
  if age_min is null or amode <> 'join' then return; end if;
  -- Already in: the join is a no-op, don't refuse it.
  if exists (select 1 from public.server_members where server_id = sid and user_id = auth.uid()) then return; end if;
  select created_at into born from public.profiles where id = auth.uid();
  if born > now() - make_interval(mins => age_min) then
    raise exception 'This server only lets in accounts older than %. Try again later.', public.new_account_label(age_min)
      using errcode = 'check_violation';
  end if;
end $$;

-- Chat mode: called by message_raid_guard for accounts younger than 7 days.
create or replace function public.new_account_chat_check(cid uuid, uid uuid, born timestamptz)
returns void language plpgsql stable security definer set search_path = public as $$
declare sid uuid; age_min int; amode text;
begin
  select s.id, s.new_account_minutes, s.new_account_mode into sid, age_min, amode
  from public.channels c join public.servers s on s.id = c.server_id where c.id = cid;
  if age_min is null or amode <> 'chat' or born <= now() - make_interval(mins => age_min) then return; end if;
  -- Server-side inserts for someone else (system messages) aren't a person posting.
  if auth.uid() is distinct from uid then return; end if;
  if public.is_staff_user(uid) or public.server_perm(sid, 'manage_messages') then return; end if;
  raise exception 'New accounts can''t chat here until they''re % old. You can chat here in %.',
    public.new_account_label(age_min), public.wait_label(born + make_interval(mins => age_min))
    using errcode = 'check_violation';
end $$;

revoke execute on function public.new_account_join_check(uuid) from public, anon, authenticated;
revoke execute on function public.new_account_chat_check(uuid, uuid, timestamptz) from public, anon, authenticated;

-- ---------- setting it ----------
create or replace function public.set_new_account_rule(sid uuid, p_minutes int, p_mode text default 'join')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'You need Manage Server for that'; end if;
  if coalesce(p_minutes, 0) = 0 then
    update public.servers set new_account_minutes = null where id = sid;
    return;
  end if;
  if not public.feature_on('raid_protection', sid) then raise exception 'The new account rule isn''t available here yet'; end if;
  if p_minutes not in (10, 60, 1440, 10080) then raise exception 'Pick 10 minutes, 1 hour, 1 day or 7 days'; end if;
  if p_mode is null or p_mode not in ('join', 'chat') then raise exception 'Pick who it applies to'; end if;
  update public.servers set new_account_minutes = p_minutes, new_account_mode = p_mode where id = sid;
end $$;
revoke execute on function public.set_new_account_rule(uuid, int, text) from public, anon;
grant execute on function public.set_new_account_rule(uuid, int, text) to authenticated;

-- ---------- patch the join paths and the message guard ----------
do $$
declare
  src text; out text;
  anchor constant text := $a$  insert into public.server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;$a$;
  guard constant text := $a$  -- 193: new account rule (join mode)
  if not staff then perform public.new_account_join_check(sid); end if;
$a$;
  msg_anchor constant text := $a$  select created_at into joined from public.profiles where id = new.author_id;$a$;
begin
  src := pg_get_functiondef('public.join_server(text)'::regprocedure);
  if position('193:' in src) = 0 then
    out := replace(src, anchor, guard || anchor);
    if out = src then raise exception '193: join_server patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.join_public_server(uuid)'::regprocedure);
  if position('193:' in src) = 0 then
    out := replace(src, anchor, guard || anchor);
    if out = src then raise exception '193: join_public_server patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.message_raid_guard()'::regprocedure);
  if position('193:' in src) = 0 then
    out := replace(src, msg_anchor, msg_anchor || $a$
  -- 193: new account rule (chat mode). Only accounts younger than the longest option pay for the lookup.
  if joined > now() - interval '7 days' then
    perform public.new_account_chat_check(new.channel_id, new.author_id, joined);
  end if;$a$);
    if out = src then raise exception '193: message_raid_guard patch did not apply'; end if;
    execute out;
  end if;
end $$;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers)
values ('raid_protection', 'Raid protection', 'Quick server lockdown and a new account rule per server', 'test', '{}')
on conflict (key) do nothing;
