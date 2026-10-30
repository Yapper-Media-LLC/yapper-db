-- 666: per-channel notification settings, like Discord (flag channel_notify). Suggestion by Autumn: "ping me on every
-- message in #verify, ignore #announcements".
--
-- Levels, per channel or as a server default (channel_id null):
--   all       every message pings: phone push, sound, pop-up and a red badge
--   mentions  today's behaviour (@you, your roles, replies, @everyone in the app)
--   none      no push, no sound, no pop-up. A direct @you or a reply to you still leaves a quiet red badge, so
--             nobody gets missed (Discord does the same); @everyone, @here and role pings don't.
-- A channel row with level null follows the server default; no row anywhere = mentions.
--
-- Mute stays where it always was (channel_reads.muted, set_muted, the bell) and server mute stays in server_mutes.
-- This only adds an end time: muted_until (null = until I turn it back on). Muting a channel hides its unread dot and
-- stops "all" pings; @mentions still come through unless the level is none (same as today's muted channels).
--
-- Push fan-out: push_on_message (438) still only looks at mentions for everyone else. For "all" it reads just the
-- rows of people who picked "all" for this channel or as this server's default, through partial indexes, so a
-- message never scans the member list. Each row pushes at most once every 10 s (last_push_at), and a message pushes
-- at most 50 people (the send route's cap too). Writes go through the two RPCs; the table is read-only to its owner.

set lock_timeout = '5s';

create table if not exists public.notify_settings (
  user_id uuid not null references public.profiles (id) on delete cascade,
  server_id uuid not null references public.servers (id) on delete cascade,
  channel_id uuid references public.channels (id) on delete cascade,
  level text,
  muted_until timestamptz,
  last_push_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint notify_settings_level check (level is null or level in ('all', 'mentions', 'none')),
  constraint notify_settings_server_level check (channel_id is not null or muted_until is null)
);
-- One row per channel, one server default per server.
create unique index if not exists notify_settings_channel_key on public.notify_settings (user_id, channel_id) where channel_id is not null;
create unique index if not exists notify_settings_server_key on public.notify_settings (user_id, server_id) where channel_id is null;
-- Foreign keys (cascades) and loading your own rows.
create index if not exists notify_settings_user_idx on public.notify_settings (user_id);
create index if not exists notify_settings_server_idx on public.notify_settings (server_id);
-- The fan-out: who picked "all" here. Also covers channel deletes.
create index if not exists notify_settings_channel_idx on public.notify_settings (channel_id, level) where channel_id is not null;
create index if not exists notify_settings_server_all on public.notify_settings (server_id) where channel_id is null and level = 'all';

alter table public.notify_settings enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'notify_settings' and policyname = 'notify settings: own read') then
    create policy "notify settings: own read" on public.notify_settings for select to authenticated using (user_id = (select auth.uid()));
  end if;
end $$;
revoke all on public.notify_settings from public, anon, authenticated;
grant select on public.notify_settings to authenticated;
grant all on public.notify_settings to service_role;

-- Pick a level for a channel (cid) or the server default (cid null). lvl null = follow the server default (channel)
-- or back to Only @mentions (server).
create or replace function public.set_notify_level(sid uuid, cid uuid, lvl text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first'; end if;
  if lvl is not null and lvl not in ('all', 'mentions', 'none') then raise exception 'Unknown setting'; end if;
  if not public.feature_on('channel_notify', sid) then raise exception 'Not available yet'; end if;
  if not exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = me) then raise exception 'Server not found'; end if;
  if cid is null then
    insert into public.notify_settings as n (user_id, server_id, channel_id, level) values (me, sid, null, lvl)
      on conflict (user_id, server_id) where channel_id is null do update set level = excluded.level, updated_at = now();
  else
    if not exists (select 1 from public.channels c where c.id = cid and c.server_id = sid) or not public.can_access_channel(cid) then
      raise exception 'Channel not found';
    end if;
    insert into public.notify_settings as n (user_id, server_id, channel_id, level) values (me, sid, cid, lvl)
      on conflict (user_id, channel_id) where channel_id is not null do update set level = excluded.level, updated_at = now();
  end if;
end; $$;
revoke all on function public.set_notify_level(uuid, uuid, text) from public, anon;
grant execute on function public.set_notify_level(uuid, uuid, text) to authenticated;

-- Mute a server channel for some minutes (15 to 1440), until turned back on (mins null), or unmute (mins 0).
-- Keeps channel_reads.muted in step, which badges, the bell and the unread counts already read.
create or replace function public.set_notify_mute(cid uuid, mins int)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid(); sid uuid; until timestamptz;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if mins is not null and (mins < 0 or mins > 1440) then raise exception 'Pick a shorter mute'; end if;
  select c.server_id into sid from public.channels c where c.id = cid;
  if sid is null or not public.can_access_channel(cid) then raise exception 'Channel not found'; end if;
  if not public.feature_on('channel_notify', sid) then raise exception 'Not available yet'; end if;
  if mins is not null and mins > 0 then until := now() + make_interval(mins => mins); end if;
  insert into public.channel_reads (user_id, channel_id, muted) values (me, cid, coalesce(mins, 1) <> 0)
    on conflict (user_id, channel_id) do update set muted = excluded.muted;
  insert into public.notify_settings as n (user_id, server_id, channel_id, muted_until) values (me, sid, cid, until)
    on conflict (user_id, channel_id) where channel_id is not null do update set muted_until = excluded.muted_until, updated_at = now();
  return until;
end; $$;
revoke all on function public.set_notify_mute(uuid, int) from public, anon;
grant execute on function public.set_notify_mute(uuid, int) to authenticated;

-- The old bell (006) and DMs keep using set_muted. It now also clears a timed mute's end time, else a mute set with
-- the bell after a timed one ran out would be lifted again on the next load.
create or replace function public.set_muted(cid uuid, mute boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.can_access_channel(cid) then raise exception 'Chat not found'; end if;
  insert into public.channel_reads (user_id, channel_id, muted)
    values (auth.uid(), cid, mute)
    on conflict (user_id, channel_id) do update set muted = excluded.muted;
  update public.notify_settings n set muted_until = null, updated_at = now()
    where n.user_id = auth.uid() and n.channel_id = cid and n.muted_until is not null;
end;
$$;
grant execute on function public.set_muted(uuid, boolean) to authenticated;

-- My settings, for the app after start-up. Timed mutes that ran out are lifted first (one indexed check when none did)
-- and come back with lifted = true, so the app can clear the bell it loaded a moment ago.
create or replace function public.my_notify_settings()
returns table (server_id uuid, channel_id uuid, level text, muted_until timestamptz, lifted boolean)
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid(); gone uuid[] := '{}';
begin
  if me is null then return; end if;
  if exists (select 1 from public.notify_settings n where n.user_id = me and n.muted_until <= now()) then
    with ended as (
      update public.notify_settings n set muted_until = null, updated_at = now()
        where n.user_id = me and n.muted_until <= now()
        returning n.channel_id
    )
    select coalesce(array_agg(e.channel_id), '{}') into gone from ended e;
    update public.channel_reads r set muted = false where r.user_id = me and r.channel_id = any (gone);
  end if;
  return query select n.server_id, n.channel_id, n.level, n.muted_until, n.channel_id = any (gone) from public.notify_settings n
    where n.user_id = me and (n.level is not null or n.muted_until is not null or n.channel_id = any (gone));
end; $$;
revoke all on function public.my_notify_settings() from public, anon;
grant execute on function public.my_notify_settings() to authenticated;

-- The push hook from 438, with the levels: "none" stops @mention pushes, "all" adds every message.
create or replace function public.push_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid; restricted boolean; body text; targets uuid[]; keep uuid[] := '{}'; uid uuid; vis boolean;
  old_claims text; old_sub text; url text; secret text; levels boolean := false; everyone_set uuid[] := '{}';
  uuid_re constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if current_setting('yapper.bulk', true) = '1' then return null; end if;
  if new.author_id is null then return null; end if;
  if not exists (select 1 from public.feature_flags f where f.key = 'mobile_app' and f.mode in ('test', 'everyone')) then return null; end if;
  if not exists (select 1 from public.push_tokens) then return null; end if;
  body := coalesce(new.content, '');
  if starts_with(body, chr(8618) || ' Forwarded' || chr(10)) then return null; end if;

  select ch.server_id,
         coalesce(ch.private, false)
         or exists (select 1 from public.channel_overrides ov where ov.channel_id = ch.id or (ch.category_id is not null and ov.category_id = ch.category_id))
    into sid, restricted
    from public.channels ch where ch.id = new.channel_id;

  if sid is null then
    select array_agg(cm.user_id) into targets from public.channel_members cm
      where cm.channel_id = new.channel_id and cm.user_id <> new.author_id;
  else
    -- Rows only exist for people the flag let in (the RPCs check it), so honour them while the flag isn't off.
    levels := exists (select 1 from public.feature_flags f where f.key = 'channel_notify' and f.mode in ('test', 'everyone'));
    -- People who picked "all" here (channel row, or the server default with no channel level of their own), not
    -- muted, and not pushed from this row in the last 10 s. Partial indexes only; no member scan. Only people with a
    -- phone (the rest would fill the 50 and never get stamped); union all so the limit stops the read early.
    if levels then
      select coalesce(array_agg(a.user_id), '{}') into everyone_set from (
        select n.user_id from public.notify_settings n
          where n.channel_id = new.channel_id and n.level = 'all' and n.user_id <> new.author_id
            and (n.last_push_at is null or n.last_push_at < now() - interval '10 seconds')
            and exists (select 1 from public.push_tokens t where t.user_id = n.user_id)
        union all
        select d.user_id from public.notify_settings d
          where d.server_id = sid and d.channel_id is null and d.level = 'all' and d.user_id <> new.author_id
            and (d.last_push_at is null or d.last_push_at < now() - interval '10 seconds')
            and exists (select 1 from public.push_tokens t where t.user_id = d.user_id)
            and not exists (select 1 from public.notify_settings c where c.user_id = d.user_id and c.channel_id = new.channel_id and c.level is not null)
        limit 50
      ) a
      -- Muted: the bell (channel_reads.muted), unless it was a timed mute that already ran out.
      where not exists (select 1 from public.channel_reads r where r.user_id = a.user_id and r.channel_id = new.channel_id and r.muted
                          and not exists (select 1 from public.notify_settings m where m.user_id = a.user_id and m.channel_id = new.channel_id and m.muted_until <= now()));
    end if;
    if (strpos(body, '<@') = 0 and new.reply_to_id is null) and cardinality(everyone_set) = 0 then return null; end if;
    select array_agg(distinct t.x) into targets from (
      (select m[1]::uuid as x from regexp_matches(body, '<@(' || uuid_re || ')>', 'g') m limit 20)
      union all
      (select mr.user_id from public.member_roles mr
        where mr.server_id = sid
          and mr.role_id in (select m[1]::uuid from regexp_matches(body, '<@&(' || uuid_re || ')>', 'g') m limit 10)
        limit 50)
      union all
      (select pm.author_id from public.messages pm where new.reply_to_id is not null and pm.id = new.reply_to_id and pm.channel_id = new.channel_id)
    ) t where t.x is not null and t.x <> new.author_id;
    -- "none" (on the channel, or the server default when the channel has no level): no mention pushes.
    if levels and targets is not null then
      select array_agg(x) into targets from unnest(targets) x
        where coalesce((select c.level from public.notify_settings c where c.user_id = x and c.channel_id = new.channel_id),
                       (select d.level from public.notify_settings d where d.user_id = x and d.server_id = sid and d.channel_id is null),
                       'mentions') <> 'none';
    end if;
    targets := (select array_agg(distinct x) from unnest(coalesce(targets, '{}') || everyone_set) x);
  end if;
  if targets is null then return null; end if;

  old_claims := current_setting('request.jwt.claims', true);
  old_sub := current_setting('request.jwt.claim.sub', true);
  foreach uid in array targets loop
    if not exists (select 1 from public.push_tokens t where t.user_id = uid) then continue; end if;
    if public.is_site_banned(uid) then continue; end if;
    if exists (select 1 from public.blocks b where b.blocker = uid and b.blocked = new.author_id) then continue; end if;
    if exists (select 1 from public.presence p where p.user_id = uid and p.pref = 'dnd') then continue; end if;
    if sid is null then
      if exists (select 1 from public.channel_reads r where r.user_id = uid and r.channel_id = new.channel_id and r.muted) then continue; end if;
    else
      if not exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = uid) then continue; end if;
      if exists (select 1 from public.server_mutes m where m.user_id = uid and m.server_id = sid) then continue; end if;
      if coalesce(restricted, false) then
        perform set_config('request.jwt.claims', jsonb_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
        perform set_config('request.jwt.claim.sub', uid::text, true);
        vis := public.can_access_channel(new.channel_id);
        perform set_config('request.jwt.claims', coalesce(nullif(old_claims, ''), '{}'), true);
        perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
        if not coalesce(vis, false) then continue; end if;
      end if;
    end if;
    keep := keep || uid;
    exit when cardinality(keep) >= 50;
  end loop;
  if cardinality(keep) = 0 then return null; end if;

  -- Only here (a real push) is there a sub-transaction: a vault or pg_net problem must never fail the message itself.
  begin
    select decrypted_secret into url from vault.decrypted_secrets where name = 'push_url';
    select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_secret';
    if url is null or secret is null then return null; end if;
    -- The per-row push rate for "all": stamp the row that picked them (the channel's, else the server default).
    -- Rows another message is stamping right now are skipped, never waited on.
    if cardinality(everyone_set) > 0 then
      update public.notify_settings n set last_push_at = now()
        where n.ctid in (
          select r.ctid from public.notify_settings r
            where r.user_id = any (keep) and r.user_id = any (everyone_set) and r.level = 'all'
              and (r.channel_id = new.channel_id
                   or (r.channel_id is null and r.server_id = sid
                       and not exists (select 1 from public.notify_settings c where c.user_id = r.user_id and c.channel_id = new.channel_id and c.level is not null)))
            for update skip locked);
    end if;
    perform net.http_post(
      url := rtrim(url, '/') || '/api/push/send',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret),
      body := jsonb_build_object('id', new.id, 'channel_id', new.channel_id, 'server_id', sid, 'author_id', new.author_id,
                                 'content', left(body, 300), 'attachment', new.attachment_path is not null, 'to', to_jsonb(keep)),
      timeout_milliseconds := 5000);
  exception when others then
    return null;
  end;
  return null;
end; $$;
revoke all on function public.push_on_message() from public, anon, authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('channel_notify', 'Channel notifications', 'Per-channel notification settings (All messages, Only @mentions, Nothing) and timed mutes, with a server default. Test: Antic only',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
