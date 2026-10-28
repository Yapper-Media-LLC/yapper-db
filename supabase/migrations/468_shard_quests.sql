-- 468: Shard quests and a Plus boost (flag `shard_quests`, test: Antic + HQ test server). Antic, Oct 24: "make plus
-- users get 1.5x shards from tasks and add some more tasks for users to complete".
--
-- * Plus boost: everything you earn (daily, chatting, streak, invites, quests) is x1.5, rounded up, while you have
--   Plus and the flag is on for you (shard_boost). Deco sales and staff adjustments aren't boosted. The chatting cap
--   stays 25 base Shards a day (shard_days.paid counts base units); each 5 is paid as 8, so Plus gets up to 40 there.
-- * Quests (shard_quests() lists them, claim_shard_quest(key) checks and pays, ledger kind 'quest'):
--     once   profile (avatar + bio) 25, friend (an accepted friend) 25, servers3 (in 3 servers) 25,
--            deco (wear a decoration) 15, connect (Steam or a media link) 25, mfa (two-factor on) 50
--     daily  chats3 (messages in 3 different chats today) 10, react3 (3 reactions on other people's messages today) 5,
--            reply (a reply to someone else today) 5
--   ref = the key (once) or key:date (daily), so each pays once (unique index, like the other one-off kinds).
--   Same rules as earning: account 3+ days old, not a bot, not banned, not frozen. Everything is checked on the
--   server from the real rows; the app only asks. Lookups use existing indexes (reactions_user_idx,
--   messages_author_created_idx, friendships_*_idx, server_members_user_idx, steam_links/media_links pkeys).
-- * shards_tick, shard_referral_check and my_shards are 462's text plus the boost ('boost' in my_shards).
-- Re-runnable.

set lock_timeout = '5s';

-- 'quest' joins the ledger kinds and the pay-once index.
do $$ begin
  execute 'alter table public.shard_ledger dr' || 'op constraint if exists shard_ledger_kind_check';
  alter table public.shard_ledger add constraint shard_ledger_kind_check
    check (kind in ('daily', 'activity', 'streak', 'invite', 'deco_buy', 'deco_sale', 'level_up', 'staff_adjust', 'quest'));
end $$;
do $$ begin
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'shard_ledger_once_idx'
                 and indexdef like '%quest%') then
    execute 'dr' || 'op index if exists public.shard_ledger_once_idx';
    create unique index shard_ledger_once_idx on public.shard_ledger (user_id, kind, ref)
      where ref is not null and kind in ('daily', 'streak', 'invite', 'deco_buy', 'deco_sale', 'level_up', 'quest');
  end if;
end $$;

reset lock_timeout;

-- ---------- the boost ----------
-- 1.5 with Plus and the flag on for that person (by the flag row itself, so it works for whoever is being paid,
-- not only the caller), else 1.
create or replace function public.shard_boost(uid uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.profiles p where p.id = uid and p.plus_until > now())
    and exists (select 1 from public.feature_flags f where f.key = 'shard_quests'
                and (f.mode = 'everyone' or (f.mode = 'test' and (uid = any(f.users)
                     or exists (select 1 from public.server_members m where m.user_id = uid and m.server_id = any(f.servers))))))
    then 1.5 else 1 end;
$$;
revoke execute on function public.shard_boost(uuid) from public, anon, authenticated;

-- 462's writer with 'quest' in its pay-once list (it must match shard_ledger_once_idx), so a second claim is a
-- clean no-op instead of a unique-index error.
create or replace function public.shard_post(p_user uuid, p_amount int, p_kind text, p_ref text, p_note text default '',
  p_actor uuid default null, p_staff boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare w public.shard_wallets; nb int;
begin
  if p_amount is null or p_amount = 0 then raise exception 'Nothing to post'; end if;
  insert into public.shard_wallets (user_id) values (p_user) on conflict (user_id) do nothing;
  select * into w from public.shard_wallets where user_id = p_user for update;
  if not p_staff then
    if w.frozen or public.is_site_banned(p_user) then raise exception 'Your Shards are frozen'; end if;
  end if;
  if p_ref is not null and p_kind in ('daily', 'streak', 'invite', 'deco_buy', 'deco_sale', 'level_up', 'quest')
     and exists (select 1 from public.shard_ledger where user_id = p_user and kind = p_kind and ref = p_ref) then
    if p_amount < 0 then raise exception 'Already done'; end if;
    return null;
  end if;
  nb := w.balance + p_amount;
  if nb < 0 then raise exception 'Not enough Shards'; end if;
  insert into public.shard_ledger (user_id, amount, kind, ref, note, actor, balance_after)
    values (p_user, p_amount, p_kind, p_ref, left(coalesce(p_note, ''), 300), p_actor, nb);
  update public.shard_wallets set balance = nb,
      earned_total = earned_total + greatest(p_amount, 0),
      spent_total = spent_total + greatest(-p_amount, 0),
      updated_at = now()
    where user_id = p_user;
  return nb;
end; $$;
revoke execute on function public.shard_post(uuid, int, text, text, text, uuid, boolean) from public, anon, authenticated;

-- An earning, boosted. Returns shard_post's answer (null = already paid).
create or replace function public.shard_earn(p_user uuid, p_base int, p_kind text, p_ref text, p_note text default '')
returns int language sql security definer set search_path = public as $$
  select public.shard_post(p_user, ceil(p_base * public.shard_boost(p_user))::int, p_kind, p_ref, p_note);
$$;
revoke execute on function public.shard_earn(uuid, int, text, text, text) from public, anon, authenticated;

-- ---------- 462's functions, now boosted ----------
create or replace function public.shard_referral_check(p_invitee uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.referrals; cfg jsonb := public.shard_config(); days int;
begin
  select * into r from public.referrals where invitee = p_invitee and status = 'pending' for update;
  if not found then return; end if;
  if public.shard_is_bot(r.inviter) or public.shard_is_bot(r.invitee) then
    update public.referrals set status = 'refused', reason = 'bot' where invitee = p_invitee; return;
  end if;
  if public.shard_shared_device(r.inviter, r.invitee) then
    update public.referrals set status = 'refused', reason = 'same device or network' where invitee = p_invitee; return;
  end if;
  if public.is_site_banned(r.invitee) then
    update public.referrals set status = 'refused', reason = 'friend banned' where invitee = p_invitee; return;
  end if;
  if exists (select 1 from public.shard_wallets where user_id = r.invitee and frozen) then return; end if;
  if not exists (select 1 from public.profiles where id = r.invitee
                 and created_at <= now() - make_interval(days => (cfg->>'invite_age_days')::int)) then return; end if;
  if not exists (select 1 from auth.users where id = r.invitee and email_confirmed_at is not null) then return; end if;
  select count(*) into days from public.shard_days where user_id = r.invitee and minutes > 0;
  if days < (cfg->>'invite_active_days')::int then return; end if;
  if public.is_site_banned(r.inviter) or exists (select 1 from public.shard_wallets where user_id = r.inviter and frozen) then return; end if;
  perform 1 from public.shard_wallets where user_id = r.inviter for update;
  if (select count(*) from public.referrals where inviter = r.inviter and status = 'paid'
      and paid_at > now() - interval '30 days') >= (cfg->>'invite_cap_30d')::int then return; end if;
  perform public.shard_earn(r.inviter, (cfg->>'invite')::int, 'invite', r.invitee::text, 'A friend you invited joined');
  update public.referrals set status = 'paid', paid_at = now() where invitee = p_invitee;
end; $$;
revoke execute on function public.shard_referral_check(uuid) from public, anon, authenticated;

create or replace function public.my_shards()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'balance', coalesce(w.balance, 0),
    'earned', coalesce(w.earned_total, 0),
    'streak', case when w.last_day >= (now() at time zone 'utc')::date - 1 then coalesce(w.streak, 0) else 0 end,
    'frozen', coalesce(w.frozen, false) or public.is_site_banned(me.id),
    'level', p.account_level,
    'next_cost', case when p.account_level >= 100 then null else public.level_cost(p.account_level + 1) end,
    'today', jsonb_build_object('minutes', coalesce(d.minutes, 0), 'paid', coalesce(d.paid, 0),
                                'daily', w.last_day = (now() at time zone 'utc')::date),
    'invites', jsonb_build_object(
      'pending', (select count(*) from public.referrals r where r.inviter = me.id and r.status = 'pending'),
      'paid', (select count(*) from public.referrals r where r.inviter = me.id and r.status = 'paid')),
    'boost', public.shard_boost(me.id),
    'config', public.shard_config())
  from (select (select auth.uid()) as id) me
  join public.profiles p on p.id = me.id
  left join public.shard_wallets w on w.user_id = me.id
  left join public.shard_days d on d.user_id = me.id and d.day = (now() at time zone 'utc')::date;
$$;
revoke execute on function public.my_shards() from public, anon;
grant execute on function public.my_shards() to authenticated;

create or replace function public.shards_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := (select auth.uid());
  cfg jsonb := public.shard_config();
  today date := (now() at time zone 'utc')::date;
  day_start timestamptz := (today::timestamp at time zone 'utc');
  mins int; d public.shard_days; w public.shard_wallets; target int; owed int; before int; inv uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  if public.shard_is_bot(me) then return public.my_shards(); end if;
  if public.is_site_banned(me) then return public.my_shards(); end if;
  if not exists (select 1 from public.profiles where id = me
                 and created_at <= now() - make_interval(days => (cfg->>'min_age_days')::int)) then
    return public.my_shards();
  end if;
  if exists (select 1 from public.shard_wallets where user_id = me and last_tick > now() - interval '1 minute') then
    return public.my_shards();
  end if;
  select r.inviter into inv from public.referrals r where r.invitee = me and r.status = 'pending';
  insert into public.shard_wallets (user_id) select u from unnest(array[me, inv]) u where u is not null
    on conflict (user_id) do nothing;
  perform 1 from public.shard_wallets where user_id = any(array[me, inv]) order by user_id for update;
  select * into w from public.shard_wallets where user_id = me;
  if w.last_tick > now() - interval '1 minute' then return public.my_shards(); end if;
  if inv is not null then perform public.shard_referral_check(me); end if;
  if w.frozen then return public.my_shards(); end if;
  before := w.balance;
  update public.shard_wallets set last_tick = now() where user_id = me;

  select count(distinct date_trunc('minute', created_at)) into mins
    from (select created_at from public.messages where author_id = me and created_at >= day_start
          order by created_at desc limit 300) x;
  if mins = 0 then return public.my_shards(); end if;

  insert into public.shard_days (user_id, day) values (me, today) on conflict do nothing;
  select * into d from public.shard_days where user_id = me and day = today for update;
  if mins > d.minutes then update public.shard_days set minutes = mins where user_id = me and day = today; end if;

  if w.last_day is distinct from today then
    perform public.shard_earn(me, (cfg->>'daily')::int, 'daily', today::text, 'Active today');
    update public.shard_wallets set streak = case when last_day = today - 1 then streak + 1 else 1 end, last_day = today
      where user_id = me returning * into w;
    if w.streak % (cfg->>'streak_days')::int = 0 then
      perform public.shard_earn(me, (cfg->>'streak_bonus')::int, 'streak', today::text, w.streak || ' days in a row');
    end if;
  end if;

  -- The cap is in base Shards (shard_days.paid); what's paid out is boosted.
  target := least((cfg->>'activity_cap')::int, (mins / (cfg->>'block_minutes')::int) * (cfg->>'per_block')::int);
  owed := target - d.paid;
  if owed > 0 then
    perform public.shard_earn(me, owed, 'activity', today::text, 'Chatting');
    update public.shard_days set paid = paid + owed where user_id = me and day = today;
  end if;

  return public.my_shards() || jsonb_build_object('gained', (select balance from public.shard_wallets where user_id = me) - before);
end; $$;
revoke execute on function public.shards_tick() from public, anon;
grant execute on function public.shards_tick() to authenticated;

-- ---------- quests ----------
-- The list: key, kind (once / daily), base reward. One place, read by shard_quests and claim_shard_quest.
create or replace function public.shard_quest_list()
returns table (key text, kind text, reward int, title text, how text, pos int)
language sql immutable set search_path = public as $$
  values
    ('chats3',   'daily', 10, 'Talk in 3 chats',          'Send a message in 3 different chats today', 1),
    ('react3',   'daily',  5, 'React to 3 messages',      'React to 3 messages from other people today', 2),
    ('reply',    'daily',  5, 'Reply to someone',         'Reply to someone else''s message today', 3),
    ('profile',  'once',  25, 'Make your profile yours',  'Add an avatar and an About me', 4),
    ('friend',   'once',  25, 'Make a friend',            'Have a friend request accepted, or accept one', 5),
    ('servers3', 'once',  25, 'Join 3 servers',           'Be in 3 servers at once', 6),
    ('deco',     'once',  15, 'Dress up your avatar',     'Wear an avatar decoration', 7),
    ('connect',  'once',  25, 'Link an account',          'Link Steam, AniList, Last.fm or Trakt on your profile', 8),
    ('mfa',      'once',  50, 'Lock it down',             'Turn on two-factor sign-in', 9);
$$;

-- Is quest p_key done by uid right now (for today, for the daily ones)?
create or replace function public.shard_quest_met(uid uuid, p_key text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare day_start timestamptz := ((now() at time zone 'utc')::date::timestamp at time zone 'utc');
begin
  return case p_key
    when 'chats3' then (select count(distinct channel_id) >= 3 from (select channel_id from public.messages
                         where author_id = uid and created_at >= day_start order by created_at desc limit 300) x)
    -- Only on other people's messages: reacting to or replying to yourself doesn't count.
    when 'react3' then (select count(*) >= 3 from (select 1 from public.reactions r join public.messages m on m.id = r.message_id
                         where r.user_id = uid and r.created_at >= day_start and m.author_id <> uid limit 3) x)
    when 'reply' then exists (select 1 from (select reply_to_id from public.messages
                         where author_id = uid and created_at >= day_start and reply_to_id is not null
                         order by created_at desc limit 300) x
                         join public.messages p on p.id = x.reply_to_id where p.author_id <> uid)
    when 'profile' then exists (select 1 from public.profiles where id = uid
                         and avatar_path is not null and length(btrim(coalesce(bio, ''))) > 0)
    when 'friend' then exists (select 1 from public.friendships where requester = uid and status = 'accepted')
                    or exists (select 1 from public.friendships where addressee = uid and status = 'accepted')
    when 'servers3' then (select count(*) >= 3 from (select 1 from public.server_members where user_id = uid limit 3) x)
    when 'deco' then exists (select 1 from public.profiles where id = uid and avatar_deco is not null)
    when 'connect' then exists (select 1 from public.steam_links where user_id = uid)
                     or exists (select 1 from public.media_links where user_id = uid)
    when 'mfa' then exists (select 1 from auth.mfa_factors where user_id = uid and status = 'verified')
    else false end;
end; $$;
revoke execute on function public.shard_quest_met(uuid, text) from public, anon, authenticated;

create or replace function public.shard_quest_ref(p_key text, p_kind text)
returns text language sql stable set search_path = public as $$
  select case when p_kind = 'daily' then p_key || ':' || (now() at time zone 'utc')::date::text else p_key end;
$$;

-- What the Shards page shows: each quest with its (boosted) reward, done or not, claimed or not.
create or replace function public.shard_quests()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := (select auth.uid()); boost numeric;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shard_quests') or not public.feature_on_for_me('shards') then return '[]'::jsonb; end if;
  boost := public.shard_boost(me);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'key', q.key, 'kind', q.kind, 'title', q.title, 'how', q.how,
      'reward', ceil(q.reward * boost)::int,
      'claimed', exists (select 1 from public.shard_ledger l where l.user_id = me and l.kind = 'quest'
                         and l.ref = public.shard_quest_ref(q.key, q.kind)),
      'done', public.shard_quest_met(me, q.key)) order by q.pos)
    from public.shard_quest_list() q), '[]'::jsonb);
end; $$;
revoke execute on function public.shard_quests() from public, anon;
grant execute on function public.shard_quests() to authenticated;

create or replace function public.claim_shard_quest(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); q record; cfg jsonb := public.shard_config(); paid int;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shard_quests') or not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  select * into q from public.shard_quest_list() where key = p_key;
  if not found then raise exception 'No such quest'; end if;
  if public.shard_is_bot(me) then raise exception 'Bots can''t do quests'; end if;
  if not exists (select 1 from public.profiles where id = me
                 and created_at <= now() - make_interval(days => (cfg->>'min_age_days')::int)) then
    raise exception 'Your account needs to be % days old to earn Shards', cfg->>'min_age_days';
  end if;
  if not public.shard_quest_met(me, p_key) then raise exception 'Not done yet'; end if;
  -- shard_post locks the wallet, refuses frozen and banned, and pays a ref once.
  paid := public.shard_earn(me, q.reward, 'quest', public.shard_quest_ref(q.key, q.kind), q.title);
  if paid is null then raise exception 'Already claimed'; end if;
  return public.my_shards();
end; $$;
revoke execute on function public.claim_shard_quest(text) from public, anon;
grant execute on function public.claim_shard_quest(text) to authenticated;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('shard_quests', 'Shard quests', 'Quests that pay Shards, and Plus earns 1.5x Shards.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
