-- In-house bots, part 2: Logger, Starboard, Giveaways. Functions, tables (starboard_posts, giveaways) and the
-- giveaways-tick cron job were applied live via MCP in pieces. The triggers are in 124 (run by hand).
-- Accounts logger@ / starboard@ / giveaways@yapper.website were made directly in auth.users, added to bot_accounts,
-- badges official_bot+bot, avatars /bots/*.svg (media_scans rows ok). server_bots.bot allows the new keys.
-- Every trigger function swallows its own errors: a bot must never break an edit, delete, ban or reaction.
-- Bot posts never ping: mentions become plain names, @everyone/@here are defused.
create or replace function public.bot_cfg(sid uuid, p_bot text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select config from public.server_bots where server_id = sid and bot = p_bot and enabled
$$;

create or replace function public.log_name(uid uuid) returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select coalesce(display_name, username) from public.profiles where id = uid), 'someone')
$$;

/** Text safe to repost: <@id> becomes @name, @everyone/@here can't ping, newlines folded. */
create or replace function public.log_clean(t text, maxlen int default 600) returns text
language plpgsql stable security definer set search_path to 'public' as $$
declare m text[]; out text := coalesce(t, '');
begin
  for m in select regexp_matches(out, '<@([0-9a-f-]{36})>', 'g') loop
    out := replace(out, '<@' || m[1] || '>', '@' || public.log_name(m[1]::uuid));
  end loop;
  out := regexp_replace(out, '@(everyone|here)', '@​\1', 'gi');
  out := replace(out, E'\n', ' ');
  if length(out) > maxlen then out := left(out, maxlen) || '…'; end if;
  return out;
end $$;

-- ---------- Logger ----------
create or replace function public.bot_log(sid uuid, body text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb; cid uuid;
begin
  if not exists (select 1 from public.servers where id = sid) then return; end if; -- server being deleted
  cfg := public.bot_cfg(sid, 'logger');
  if cfg is null then return; end if;
  cid := nullif(cfg ->> 'channel_id', '')::uuid;
  if cid is null or not exists (select 1 from public.channels where id = cid and server_id = sid) then return; end if;
  perform public.bot_say(cid, 'logger', body);
exception when others then return;
end $$;

create or replace function public.logger_messages() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid; cname text; cfg jsonb; actor uuid := auth.uid(); txt text;
begin
  if current_setting('yapper.bulk', true) = '1' or current_setting('yapper.bot', true) = '1' then return null; end if;
  select server_id, name into sid, cname from public.channels where id = old.channel_id;
  if sid is null then return null; end if;
  cfg := public.bot_cfg(sid, 'logger');
  if cfg is null or (cfg ->> 'channel_id') = old.channel_id::text then return null; end if;
  if exists (select 1 from public.bot_accounts where user_id = old.author_id) then return null; end if;
  if tg_op = 'UPDATE' then
    if new.content is not distinct from old.content then return null; end if;
    txt := '✏️ **' || public.log_name(old.author_id) || '** edited a message in **#' || cname || '**'
      || E'\nBefore: ' || public.log_clean(old.content, 500) || E'\nAfter: ' || public.log_clean(new.content, 500);
  else
    txt := '🗑️ A message by **' || public.log_name(old.author_id) || '** in **#' || cname || '** was deleted'
      || case when actor is not null and actor <> old.author_id then ' by **' || public.log_name(actor) || '**' else '' end
      || case when coalesce(old.content, '') <> '' then E'\n' || public.log_clean(old.content, 800) else '' end
      || case when old.attachment_path is not null then E'\n(it had an attachment)' else '' end;
  end if;
  perform public.bot_log(sid, txt);
  return null;
exception when others then return null;
end $$;
drop trigger if exists messages_logger on public.messages;
create trigger messages_logger after update of content or delete on public.messages
  for each row execute function public.logger_messages();

create or replace function public.logger_members() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare actor uuid := auth.uid(); age interval; txt text;
begin
  if current_setting('yapper.bulk', true) = '1' then return null; end if;
  if public.bot_cfg(coalesce(new.server_id, old.server_id), 'logger') is null then return null; end if;
  if tg_op = 'INSERT' then
    select now() - created_at into age from public.profiles where id = new.user_id;
    txt := '📥 **' || public.log_name(new.user_id) || '** joined'
      || case when age < interval '1 day' then ' · ⚠️ account made today'
              when age < interval '7 days' then ' · account made ' || extract(day from age)::int || ' days ago' else '' end;
    perform public.bot_log(new.server_id, txt);
  else
    txt := '📤 **' || public.log_name(old.user_id) || '** '
      || case when actor is not null and actor <> old.user_id then 'was kicked by **' || public.log_name(actor) || '**' else 'left' end;
    perform public.bot_log(old.server_id, txt);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists server_members_logger on public.server_members;
create trigger server_members_logger after insert or delete on public.server_members
  for each row execute function public.logger_members();

create or replace function public.logger_bans() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'INSERT' then
    perform public.bot_log(new.server_id, '🔨 **' || public.log_name(new.user_id) || '** was banned'
      || case when new.banned_by is not null then ' by **' || public.log_name(new.banned_by) || '**' else '' end);
  else
    perform public.bot_log(old.server_id, '✅ **' || public.log_name(old.user_id) || '** was unbanned'
      || case when auth.uid() is not null then ' by **' || public.log_name(auth.uid()) || '**' else '' end);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists server_bans_logger on public.server_bans;
create trigger server_bans_logger after insert or delete on public.server_bans
  for each row execute function public.logger_bans();

create or replace function public.logger_timeouts() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.until <= now() then
    perform public.bot_log(new.server_id, '🔈 **' || public.log_name(new.user_id) || '**''s timeout was lifted'
      || case when auth.uid() is not null then ' by **' || public.log_name(auth.uid()) || '**' else '' end);
  else
    perform public.bot_log(new.server_id, '⏳ **' || public.log_name(new.user_id) || '** was timed out until '
      || to_char(new.until at time zone 'UTC', 'Mon DD HH24:MI') || ' UTC'
      || case when new.set_by is not null then ' by **' || public.log_name(new.set_by) || '**' else '' end
      || case when coalesce(new.reason, '') <> '' then ': ' || public.log_clean(new.reason, 200) else '' end);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists server_timeouts_logger on public.server_timeouts;
create trigger server_timeouts_logger after insert or update on public.server_timeouts
  for each row execute function public.logger_timeouts();

create or replace function public.logger_roles() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare actor uuid := auth.uid(); rname text; r record;
begin
  if actor is null or current_setting('yapper.bot', true) = '1' or current_setting('yapper.bulk', true) = '1' then return null; end if;
  r := coalesce(new, old);
  select name into rname from public.roles where id = r.role_id;
  if rname is null then return null; end if; -- the role itself is being deleted
  if tg_op = 'DELETE' and not exists (select 1 from public.server_members where server_id = r.server_id and user_id = r.user_id) then return null; end if; -- they left
  perform public.bot_log(r.server_id, '🏷️ **' || public.log_name(actor) || '** '
    || case when tg_op = 'INSERT' then 'gave **' || public.log_name(r.user_id) || '** the **' || rname || '** role'
            else 'took the **' || rname || '** role from **' || public.log_name(r.user_id) || '**' end);
  return null;
exception when others then return null;
end $$;
drop trigger if exists member_roles_logger on public.member_roles;
create trigger member_roles_logger after insert or delete on public.member_roles
  for each row execute function public.logger_roles();

-- ---------- Starboard ----------
create table if not exists public.starboard_posts (
  message_id uuid primary key references public.messages(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  post_id uuid,
  created_at timestamptz not null default now()
);
alter table public.starboard_posts enable row level security;

create or replace function public.starboard_react() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare m public.messages; ch public.channels; cfg jsonb; target uuid; need int; n int; pid uuid;
begin
  if new.emoji not in ('⭐', '🌟') then return null; end if;
  select * into m from public.messages where id = new.message_id;
  if m.id is null then return null; end if;
  select * into ch from public.channels where id = m.channel_id;
  if ch.server_id is null or ch.private then return null; end if;
  cfg := public.bot_cfg(ch.server_id, 'starboard');
  if cfg is null then return null; end if;
  target := nullif(cfg ->> 'channel_id', '')::uuid;
  if target is null or target = ch.id or not exists (select 1 from public.channels where id = target and server_id = ch.server_id) then return null; end if;
  if exists (select 1 from public.starboard_posts where message_id = m.id) then return null; end if;
  need := least(greatest(coalesce(nullif(cfg ->> 'threshold', '')::int, 5), 1), 50);
  select count(distinct user_id) into n from public.reactions where message_id = m.id and emoji in ('⭐', '🌟') and user_id <> m.author_id;
  if n < need then return null; end if;
  insert into public.starboard_posts (message_id, server_id) values (m.id, ch.server_id) on conflict do nothing;
  if not found then return null; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, attachment_path, attachment_width, attachment_height, attachment_name, attachment_size)
  values (target, public.bot_id('starboard'),
          '⭐ **' || n || '** · **#' || ch.name || '** · **' || public.log_name(m.author_id) || '**'
            || case when coalesce(m.content, '') <> '' then E'\n' || public.log_clean(m.content, 1500) else '' end,
          m.attachment_path, m.attachment_width, m.attachment_height, m.attachment_name, m.attachment_size)
  returning id into pid;
  perform set_config('yapper.bot', '', true);
  update public.starboard_posts set post_id = pid where message_id = m.id;
  return null;
exception when others then
  perform set_config('yapper.bot', '', true);
  return null;
end $$;
drop trigger if exists reactions_starboard on public.reactions;
create trigger reactions_starboard after insert on public.reactions
  for each row execute function public.starboard_react();

-- ---------- Giveaways ----------
create table if not exists public.giveaways (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  channel_id uuid not null references public.channels(id) on delete cascade,
  message_id uuid references public.messages(id) on delete cascade,
  host_id uuid,
  prize text not null,
  winners int not null default 1,
  ends_at timestamptz not null,
  ended_at timestamptz,
  winner_ids uuid[] not null default '{}'
);
create index if not exists giveaways_due on public.giveaways (ends_at) where ended_at is null;
alter table public.giveaways enable row level security;
drop policy if exists "giveaways in my servers" on public.giveaways;
create policy "giveaways in my servers" on public.giveaways for select to authenticated using (server_id in (select public.my_server_ids()));

create or replace function public.giveaway_end(gid uuid, reroll boolean default false) returns void
language plpgsql security definer set search_path to 'public' as $$
declare g public.giveaways; picks uuid[]; txt text;
begin
  select * into g from public.giveaways where id = gid;
  if g.id is null or (g.ended_at is not null and not reroll) then return; end if;
  select coalesce(array_agg(u), '{}') into picks from (
    select r.user_id as u from public.reactions r
    where r.message_id = g.message_id and r.emoji = '🎉'
      and not exists (select 1 from public.bot_accounts b where b.user_id = r.user_id)
      and exists (select 1 from public.server_members sm where sm.server_id = g.server_id and sm.user_id = r.user_id)
      and not (reroll and r.user_id = any(g.winner_ids))
    group by r.user_id order by random() limit g.winners) x;
  if coalesce(array_length(picks, 1), 0) = 0 then
    txt := '😶 Nobody' || case when reroll then ' else' else '' end || ' entered the giveaway for **' || public.log_clean(g.prize, 200) || '**, so there''s no winner.';
  else
    txt := '🎉 Congratulations ' || (select string_agg('<@' || p || '>', ', ') from unnest(picks) p) || '! You won **' || public.log_clean(g.prize, 200) || '**'
      || case when reroll then ' (reroll)' else '' end || '.';
  end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id)
  values (g.channel_id, public.bot_id('giveaways'), txt, g.message_id);
  perform set_config('yapper.bot', '', true);
  update public.giveaways set ended_at = coalesce(ended_at, now()), winner_ids = case when reroll then winner_ids || picks else picks end where id = gid;
exception when others then
  perform set_config('yapper.bot', '', true);
end $$;

create or replace function public.giveaways_tick() returns void
language plpgsql security definer set search_path to 'public' as $$
declare gid uuid;
begin
  for gid in select id from public.giveaways where ended_at is null and ends_at <= now() order by ends_at limit 25 loop
    perform public.giveaway_end(gid);
  end loop;
end $$;

create or replace function public.giveaway_cmd() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid; cmd text; rest text; m text[]; dur interval; nwin int := 1; prize text; mid uuid; gid uuid; ends timestamptz; ok boolean;
begin
  if left(new.content, 1) <> '!' or current_setting('yapper.bot', true) = '1' then return null; end if;
  cmd := lower(split_part(new.content, ' ', 1));
  if cmd not in ('!giveaway', '!gstart', '!gend', '!greroll') then return null; end if;
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null or public.bot_cfg(sid, 'giveaways') is null then return null; end if;
  ok := public.server_perm(sid, 'manage_messages') or public.server_perm(sid, 'manage_server');
  if not ok then
    perform public.bot_say(new.channel_id, 'giveaways', 'Only people who can manage messages can run giveaways.');
    return null;
  end if;
  if cmd in ('!gend', '!greroll') then
    select id into gid from public.giveaways where channel_id = new.channel_id
      and (case when cmd = '!gend' then ended_at is null else ended_at is not null end)
      order by coalesce(ended_at, ends_at) desc limit 1;
    if gid is null then
      perform public.bot_say(new.channel_id, 'giveaways', case when cmd = '!gend' then 'No giveaway running in this channel.' else 'No finished giveaway here to reroll.' end);
    else
      perform public.giveaway_end(gid, cmd = '!greroll');
    end if;
    return null;
  end if;
  rest := btrim(substr(new.content, length(cmd) + 2));
  m := regexp_match(rest, '^(\d{1,4})\s*(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?|w|wks?|weeks?)\s+(?:(\d{1,2})\s*w(?:inners?)?\s+)?(.+)$', 'i');
  if m is null then
    perform public.bot_say(new.channel_id, 'giveaways', 'How to start one: `!giveaway 1d Cool prize` (or `2h`, `30m`, `1w`). For more winners: `!giveaway 1d 3w Cool prize`. End early with `!gend`, pick again with `!greroll`.');
    return null;
  end if;
  dur := (m[1] || ' ' || case lower(left(m[2], 1)) when 's' then 'seconds' when 'm' then 'minutes' when 'h' then 'hours' when 'd' then 'days' else 'weeks' end)::interval;
  dur := least(greatest(dur, interval '1 minute'), interval '30 days');
  if m[3] is not null then nwin := least(greatest(m[3]::int, 1), 20); end if;
  prize := left(btrim(m[4]), 200);
  ends := now() + dur;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content)
  values (new.channel_id, public.bot_id('giveaways'),
    '🎉 **GIVEAWAY** 🎉' || E'\n**' || public.log_clean(prize, 200) || '**'
    || E'\nReact with 🎉 to enter!'
    || E'\n' || nwin || ' winner' || case when nwin > 1 then 's' else '' end
    || ' · ends ' || to_char(ends at time zone 'UTC', 'Mon DD, HH24:MI') || ' UTC · hosted by **' || public.log_name(new.author_id) || '**')
  returning id into mid;
  begin
    insert into public.reactions (message_id, user_id, emoji) values (mid, public.bot_id('giveaways'), '🎉');
  exception when others then null; -- the giveaway still works without the starter reaction
  end;
  perform set_config('yapper.bot', '', true);
  insert into public.giveaways (server_id, channel_id, message_id, host_id, prize, winners, ends_at)
  values (sid, new.channel_id, mid, new.author_id, prize, nwin, ends);
  return null;
exception when others then
  perform set_config('yapper.bot', '', true);
  return null;
end $$;
drop trigger if exists messages_giveaways on public.messages;
create trigger messages_giveaways after insert on public.messages
  for each row execute function public.giveaway_cmd();

select cron.unschedule('giveaways-tick') where exists (select 1 from cron.job where jobname = 'giveaways-tick');
select cron.schedule('giveaways-tick', '* * * * *', 'select public.giveaways_tick()');
