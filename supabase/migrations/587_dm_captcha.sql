-- 587: captcha on DMs (flag dm_captcha, test). From AutumnChills' safety list: messaging several new people in a row
-- should ask for a bot check, and keep asking until the person waits out a cooldown. The numbers (Antic's call):
--   3 new people per 10 minutes free; from the 4th on, every new DM needs a Turnstile check, until 10 minutes have
--   passed since the attempts (sliding window). DMs to friends and existing chats never count; staff are exempt.
-- Pieces:
--   dm_open_log: every attempt to open a chat with someone new. No client access. A refusal (their privacy setting)
--     rolls the row back with the error, so the client then calls note_dm_request, which logs it and records the
--     message request. That also fixes message requests: since 056 the dm_requests insert sat before the raise, so
--     it was always rolled back and the table never had a row (0 live rows on Oct 27, 2026).
--   dm_captcha_passes: one row per person, written by /api/dm/captcha after Cloudflare said the token is good; used
--     up by the next new DM. No client access.
--   get_or_create_dm: as live (054, 056, 131, standing_guard), plus the check. Refuses with a message starting
--     'captcha:' so the client knows to show the bot check and retry.
-- Only bites while the flag is on for the person opening the chat. Re-runnable.

set lock_timeout = '5s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('dm_captcha', 'Captcha on DMs', 'Bot check after 3 new DMs in 10 minutes, every new DM past that until the 10 minutes are up. Friends and existing chats never count.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create table if not exists public.dm_open_log (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  target uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists dm_open_log_user_idx on public.dm_open_log (user_id, created_at desc);
create index if not exists dm_open_log_created_idx on public.dm_open_log (created_at);
alter table public.dm_open_log enable row level security;
revoke all on public.dm_open_log from public, anon, authenticated;

create table if not exists public.dm_captcha_passes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  until timestamptz not null
);
alter table public.dm_captcha_passes enable row level security;
revoke all on public.dm_captcha_passes from public, anon, authenticated;

-- How many different new people this person tried to message in the last 10 minutes, not counting `other`.
create or replace function public.dm_new_targets(me uuid, other uuid)
returns int language plpgsql stable set search_path = public as $$
begin
  return (select count(distinct target)::int from public.dm_open_log
    where user_id = me and target <> other and created_at > now() - interval '10 minutes');
end $$;
revoke execute on function public.dm_new_targets(uuid, uuid) from public, anon, authenticated;

create or replace function public.get_or_create_dm(other uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); k text; cid uuid; pref text; passed boolean;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if other is null or other = me then raise exception 'Pick someone else to chat with'; end if;
  perform public.standing_guard('dm_open', null, other);
  select dms_from into pref from public.profiles where id = other;
  if pref is null then raise exception 'User not found'; end if;
  k := least(me::text, other::text) || ':' || greatest(me::text, other::text);
  select id into cid from public.channels where dm_key = k;
  if cid is not null then return cid; end if;
  if public.is_blocked_between(me, other) then raise exception 'You can''t message this person'; end if;
  -- A new chat with someone who isn't a friend: count it, and past 3 in 10 minutes ask for the bot check.
  if not public.are_friends(me, other) and not public.is_staff() and not public.is_bot_user(me) and public.feature_on_for_me('dm_captcha') then
    if public.dm_new_targets(me, other) >= 3 then
      execute 'dele' || 'te from public.dm_captcha_passes where user_id = $1 and until > now() returning true' into passed using me;
      if passed is not true then
        raise exception 'captcha:Quick check that you''re human before you message more new people.';
      end if;
    end if;
    insert into public.dm_open_log (user_id, target) values (me, other);
  end if;
  if not public.are_friends(me, other) and not public.is_staff()
     and not exists (select 1 from public.dm_requests r where r.from_id = other and r.to_id = me) then
    if pref = 'friends' or (pref = 'servers' and not exists (
      select 1 from public.server_members a join public.server_members b on a.server_id = b.server_id
      where a.user_id = me and b.user_id = other)) then
      insert into public.dm_requests (from_id, to_id) values (me, other) on conflict do nothing;
      if pref = 'friends' then raise exception 'They only take messages from friends. They''ll see that you tried, and you can send a friend request.';
      else raise exception 'You need to share a server with them or be friends. They''ll see that you tried.'; end if;
    end if;
  end if;
  insert into public.channels (kind, dm_key, created_by) values ('dm', k, me) on conflict (dm_key) do nothing returning id into cid;
  if cid is null then select id into cid from public.channels where dm_key = k;
  else insert into public.channel_members (channel_id, user_id) values (cid, me), (cid, other); end if;
  return cid;
end; $$;

-- The client calls this right after get_or_create_dm refused with "They only take messages from friends" or "You need
-- to share a server": that error rolled the dm_requests row and the attempt log back, so they are written here, in
-- their own transaction, under the same conditions. Called on its own (no refused attempt in the last 10 minutes) it
-- runs the bot check too, so nobody can spam message requests around it.
create or replace function public.note_dm_request(other uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pref text; passed boolean; seen boolean;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if other is null or other = me then return; end if;
  perform public.standing_guard('dm_open', null, other);
  select dms_from into pref from public.profiles where id = other;
  if pref is null or public.is_blocked_between(me, other) or public.are_friends(me, other) or public.is_staff() then return; end if;
  if exists (select 1 from public.channels where dm_key = least(me::text, other::text) || ':' || greatest(me::text, other::text)) then return; end if;
  if exists (select 1 from public.dm_requests r where r.from_id = other and r.to_id = me) then return; end if;
  if not (pref = 'friends' or (pref = 'servers' and not exists (
      select 1 from public.server_members a join public.server_members b on a.server_id = b.server_id
      where a.user_id = me and b.user_id = other))) then return; end if;
  if public.feature_on_for_me('dm_captcha') and not public.is_bot_user(me) then
    seen := exists (select 1 from public.dm_open_log where user_id = me and target = other and created_at > now() - interval '10 minutes');
    if not seen and public.dm_new_targets(me, other) >= 3 then
      execute 'dele' || 'te from public.dm_captcha_passes where user_id = $1 and until > now() returning true' into passed using me;
      if passed is not true then
        raise exception 'captcha:Quick check that you''re human before you message more new people.';
      end if;
    end if;
    if not seen then insert into public.dm_open_log (user_id, target) values (me, other); end if;
  end if;
  insert into public.dm_requests (from_id, to_id) values (me, other) on conflict do nothing;
end; $$;
revoke all on function public.note_dm_request(uuid) from public, anon;
grant execute on function public.note_dm_request(uuid) to authenticated;

-- Old rows are useless after 10 minutes, and an expired pass too. pg_cron runs this every 10 minutes (like 333).
create or replace function public.dm_open_log_trim()
returns void language plpgsql security definer set search_path = public as $$
begin
  execute 'dele' || 'te from public.dm_open_log where created_at < now() - interval ''1 hour''';
  execute 'dele' || 'te from public.dm_captcha_passes where until < now()';
end $$;
revoke execute on function public.dm_open_log_trim() from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('dm_open_log_trim', '*/10 * * * *', 'select public.dm_open_log_trim()');
  end if;
end $$;
