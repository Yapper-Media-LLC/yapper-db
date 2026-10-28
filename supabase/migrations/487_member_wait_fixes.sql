-- 487 (applied live as 485_member_wait_fixes 09:33 UTC Oct 25, renamed: 485 was taken by hq_day_one_media): new-member wait fixes (bug reports 4b5036f2, bf86b5fb).
--
-- 1. Reacting during the new account wait (4b5036f2). Messages are held back by two account-age rules that reactions
--    skipped: HQ's wait for brand-new accounts (app_settings.new_account_wait, 10 minutes, message_raid_guard) and a
--    server's new account rule in chat mode (servers.new_account_minutes, 193's new_account_chat_check). Discord
--    blocks reacting during the wait too, so reaction_verification_guard now also asks reaction_new_account_check.
--    Same exemptions as for messages: bots (yapper.bot) skip both, staff and Manage Messages skip the server rule,
--    nobody skips HQ's wait. (Verification level / raid mode already covered reactions through server_gate.)
--    Cost: only after server_gate said yes, one primary-key read of the profile; accounts older than 7 days (the
--    longest rule) stop there. Younger ones add one primary-key read of the server and the one-row app_settings.
--
-- 2. Leaving and rejoining skipped the "member for 5 minutes" wait (bf86b5fb). 105's keep_first_join puts the FIRST
--    join time back into server_members.joined_at on rejoin (so "joined before X" roles survive), and server_gate
--    timed the wait from that, so the wait had already run out. The latest join is now kept too
--    (server_first_joins.last_joined_at, nullable: no table rewrite) and server_gate times the wait (and the raid
--    alarm's "joined in the last hour") from whichever is later. joined_at itself is unchanged.
--    Cost: one more primary-key lookup in server_gate, only past its "nothing on here" early return.
--
-- Re-runnable.

set local lock_timeout = '2s';

-- ---------- 2. last join ----------
alter table public.server_first_joins add column if not exists last_joined_at timestamptz;

create or replace function public.keep_first_join() returns trigger
language plpgsql security definer set search_path = public as $$
declare first timestamptz; j timestamptz := coalesce(new.joined_at, now());
begin
  -- Already a member: join_server's insert is a no-op (on conflict do nothing), but before-insert triggers still run.
  -- Don't restart the wait for someone clicking an invite to a server they're in.
  if exists (select 1 from public.server_members where server_id = new.server_id and user_id = new.user_id) then return new; end if;
  -- 487: remember the latest join as well, for the new member wait (server_gate).
  insert into public.server_first_joins as f (server_id, user_id, first_joined_at, last_joined_at)
    values (new.server_id, new.user_id, j, j)
    on conflict (server_id, user_id) do update set last_joined_at = excluded.last_joined_at
    returning f.first_joined_at into first;
  if first is not null and first < j then new.joined_at := first; end if;
  return new;
end; $$;

-- Live body of 333's server_gate, with the join time read as the later of joined_at and the last (re)join.
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
  -- 487: joined_at holds the first join (105); a rejoin restarts the wait, so take the later of the two.
  select greatest(m.joined_at, f.last_joined_at) into joined
    from public.server_members m
    left join public.server_first_joins f on f.server_id = m.server_id and f.user_id = m.user_id
    where m.server_id = sid and m.user_id = uid;
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
revoke execute on function public.server_gate(uuid, uuid, boolean) from public, anon, authenticated;

-- ---------- 1. reactions during the new account wait ----------
-- Why uid can't react in server sid yet because their account is too new, or null.
create or replace function public.reaction_new_account_check(sid uuid, uid uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare born timestamptz; age_min int; amode text; def uuid; wait interval;
begin
  select created_at into born from public.profiles where id = uid;
  -- Older than the longest rule (7 days): nothing more to read.
  if born is null or born <= now() - interval '7 days' then return null; end if;
  -- HQ: brand-new accounts wait (message_raid_guard). Nobody but bots skips it there either.
  select default_server_id, new_account_wait into def, wait from public.app_settings limit 1;
  if def is not null and sid = def and wait is not null and born > now() - wait then
    return 'Welcome! New accounts can react here ' || public.wait_label(born + wait) || ' from now.';
  end if;
  -- A server's new account rule, chat mode (193).
  select new_account_minutes, new_account_mode into age_min, amode from public.servers where id = sid;
  if age_min is null or amode <> 'chat' or born <= now() - make_interval(mins => age_min) then return null; end if;
  if public.is_staff_user(uid) or public.server_perm_user(sid, uid, 'manage_messages') then return null; end if;
  return 'New accounts can''t react here until they''re ' || public.new_account_label(age_min) || ' old. You can react here in '
    || public.wait_label(born + make_interval(mins => age_min)) || '.';
end $$;
revoke execute on function public.reaction_new_account_check(uuid, uuid) from public, anon, authenticated;

create or replace function public.reaction_verification_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; why text;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  if auth.uid() is distinct from new.user_id then return new; end if;
  select c.server_id into sid from public.messages m join public.channels c on c.id = m.channel_id where m.id = new.message_id;
  if sid is null then return new; end if;
  why := public.server_gate(sid, new.user_id, false);
  -- 487: the account-age waits messages already have (HQ's, and a server's new account rule in chat mode).
  if why is null then why := public.reaction_new_account_check(sid, new.user_id); end if;
  if why is not null then raise exception '%', why using errcode = 'check_violation'; end if;
  return new;
end $$;
