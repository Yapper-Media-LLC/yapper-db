-- Cut Supabase realtime fan-out (billed per message delivered to each subscriber).
--
-- 1. Online status no longer uses a presence channel (every join/leave was pushed to
--    everyone online). Clients save a heartbeat every ~45s and ask "who changed?" every ~45s.
-- 2. Server messages and reactions go to the channel's own topic (chan:<id>) instead of the
--    whole server, so only people looking at that channel get them. @mentions are also sent
--    to the mentioned person's own topic so pings stay instant. Everything else shows up as
--    unread badges from a periodic refresh.
-- 3. Member joins/leaves in big servers (over 1000 members) are not broadcast to the server;
--    only the person affected hears about it. The member list refreshes itself.

-- ---------- 1. Heartbeat presence ----------

create table if not exists public.presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  status text not null default 'online' check (status in ('online', 'idle', 'dnd')),
  last_seen timestamptz not null default now(),
  online_since timestamptz not null default now(),
  status_at timestamptz not null default now()
);
alter table public.presence enable row level security;
-- No policies on purpose: only the functions below touch it.
create index if not exists presence_last_seen on public.presence (last_seen);

-- "I'm here" (or, for invisible, "I just left"). Someone counts as online for 100s after a heartbeat.
create or replace function public.heartbeat(st text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then return; end if;
  if st is null or st = 'invisible' or st = 'off' then
    -- Expire right now: this lands in the "went offline" window of the next poll.
    update public.presence set last_seen = now() - interval '100 seconds' where user_id = me and last_seen > now() - interval '100 seconds';
    return;
  end if;
  if st not in ('online', 'idle', 'dnd') then st := 'online'; end if;
  insert into public.presence (user_id, status) values (me, st)
  on conflict (user_id) do update set
    last_seen = now(),
    online_since = case when presence.last_seen < now() - interval '100 seconds' then now() else presence.online_since end,
    status = excluded.status,
    status_at = case when presence.status is distinct from excluded.status then now() else presence.status_at end;
end;
$$;
grant execute on function public.heartbeat(text) to authenticated;

-- Who is online among the members of one server plus some extra people (friends, DM partners).
-- With `since` (the `now` from the last call) only changes come back: people who came online or
-- changed status, and people who went offline since then. Without it, everyone online.
create or replace function public.who_online(sid uuid, extra uuid[], since timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  ttl interval := interval '100 seconds';
  ids uuid[] := (coalesce(extra, '{}'::uuid[]))[1:500];
  rows jsonb;
begin
  if me is null then return '{}'::jsonb; end if;
  if sid is not null and not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then sid := null; end if;
  select coalesce(jsonb_agg(jsonb_build_array(p.user_id, case when p.last_seen > now() - ttl then p.status else 'off' end)), '[]'::jsonb)
    into rows
  from public.presence p
  where p.last_seen > now() - ttl - (case when since is null then interval '0' else ttl end)
    and (p.user_id = any(ids) or (sid is not null and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.user_id)))
    and (
      (since is null and p.last_seen > now() - ttl)
      or (since is not null and (p.online_since > since or p.status_at > since or (p.last_seen <= now() - ttl and p.last_seen > since - ttl)))
    );
  return jsonb_build_object('now', now(), 'rows', rows);
end;
$$;
grant execute on function public.who_online(uuid, uuid[], timestamptz) to authenticated;

-- ---------- 2. Messages and reactions per channel, mentions to the person ----------

create or replace function public.broadcast_message_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare cid uuid; sid uuid; uid uuid; seen uuid[] := '{}';
begin
  cid := coalesce(new.channel_id, old.channel_id);
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform realtime.broadcast_changes('chan:' || cid, 'message', tg_op, tg_table_name, tg_table_schema, new, old);
    -- @mentions ping straight away even when that person is looking elsewhere (at most 20 people).
    if tg_op = 'INSERT' and new.content like '%<@%' then
      for uid in (
        select distinct m[1]::uuid from regexp_matches(new.content, '<@([0-9a-f-]{36})>', 'g') m limit 20
      ) loop
        if uid <> new.author_id and exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = uid) then
          perform realtime.broadcast_changes('user:' || uid, 'message', tg_op, tg_table_name, tg_table_schema, new, old);
        end if;
      end loop;
    end if;
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      perform realtime.broadcast_changes('user:' || uid, 'message', tg_op, tg_table_name, tg_table_schema, new, old);
    end loop;
  end if;
  return null;
end;
$$;

create or replace function public.broadcast_reaction_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare cid uuid; sid uuid; uid uuid;
begin
  select channel_id into cid from public.messages where id = coalesce(new.message_id, old.message_id);
  if cid is null then return null; end if;
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform realtime.broadcast_changes('chan:' || cid, 'reaction', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      perform realtime.broadcast_changes('user:' || uid, 'reaction', tg_op, tg_table_name, tg_table_schema, new, old);
    end loop;
  end if;
  return null;
end;
$$;

-- ---------- 3. Member changes: quiet in big servers ----------

create or replace function public.broadcast_member_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid := coalesce(new.server_id, old.server_id); uid uuid := coalesce(new.user_id, old.user_id); n int;
begin
  select count(*) into n from (select 1 from public.server_members where server_id = sid limit 1001) t;
  if n > 1000 then
    -- Only the person who joined/left/was renamed needs to know right away.
    perform realtime.broadcast_changes('user:' || uid, 'member', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    perform realtime.broadcast_changes('server:' || sid, 'member', tg_op, tg_table_name, tg_table_schema, new, old);
  end if;
  return null;
end;
$$;
