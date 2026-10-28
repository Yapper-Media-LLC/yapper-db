-- 331: four holes from the 21 Oct bug reports. Functions, one small table, one trigger. Re-runnable.
--
--  1. Taken-down servers (572b9962). A taken-down server (servers.shut_down_at) was only hidden by the app: its members
--     could still read every message through the Mentions inbox (@everyone pings), search, or by reading `messages`
--     directly. can_access_channel (reads of messages and reactions, and realtime joins), my_mentions and
--     search_messages_v2 now treat a taken-down server as closed. Yapper staff still see it (moderation). The channel
--     list (visible_server_channels) is untouched on purpose: the app uses it to draw the "taken down" screen.
--  2. Promote channel (99d56869). #promote-your-server only checked that the text had an invite link, so anyone could
--     promote a server they are not in, and a second account skipped the one-post-per-6-hours limit. Each Yapper invite
--     must now be a real invite to a live server the poster is a member of, and a server can be promoted once per
--     6 hours however many accounts post it (new table promo_invite_marks). Discord/Telegram/Guilded links keep the
--     per-person limit only (they can't be checked).
--  3. Reactions (2ebfe535). Timed-out people (site or server timeout) and very limited accounts could still react,
--     which let them talk while muted. A new BEFORE INSERT trigger (reaction_guard) refuses the timed-out, and
--     standing_guard now refuses 'react' for very_limited accounts (suspended already was). Staff, the system and the
--     paths that set yapper.bot skip it; a bot reacting with its own login is checked like a person.
--     Plain "limited" accounts can still react.
--  4. Username hold message (72c053f8, 6cf2d480). A name someone changed away from in the last 7 days is held, but the
--     refusal said only "That username is taken", so a free-looking name looked like a bug. It now says it is held and
--     until when (the app shows the time in the reader's zone). Same rule, same error code.
--
-- Live definitions patched in place from pg_get_functiondef (Oct 21): can_access_channel(uuid), my_mentions(integer),
-- search_messages_v2(...), standing_guard(...), username_holds_guard(). Only the lines below change; signatures,
-- security definer, search_path and grants stay. invites_only_in_promo() is the live text plus the invite checks.
-- If a patch can't find its line the whole migration stops (the function changed: read it again).
-- Re-runnable, and written so the Supabase MCP can apply it in one call.

set lock_timeout = '2s';

-- ---------- 1 + 3 + 4: patch live functions by exact line ----------

do $$
declare p record; d text; n text; n_hits int;
begin
  for p in
    select * from (values
      ('public.can_access_channel(uuid)',
       $a$where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)$a$,
       $a$where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
          and not exists (select 1 from public.servers sd where sd.id = c.server_id and sd.shut_down_at is not null and not public.is_staff())$a$,
       'sd.shut_down_at', 1),
      ('public.my_mentions(integer)',
       $a$join public.server_members sm on sm.server_id = v.server_id and sm.user_id = (select auth.uid())$a$,
       $a$join public.server_members sm on sm.server_id = v.server_id and sm.user_id = (select auth.uid())
    where not exists (select 1 from public.servers sd where sd.id = v.server_id and sd.shut_down_at is not null and not public.is_staff())$a$,
       'sd.shut_down_at', 1),
      ('public.search_messages_v2(text, uuid, uuid, uuid, timestamp with time zone)',
       $a$where (cid is null or c.id = cid)$a$,
       $a$where (cid is null or c.id = cid)
      and not exists (select 1 from public.servers sd where sd.id = c.server_id and sd.shut_down_at is not null and not public.is_staff())$a$,
       'sd.shut_down_at', 1),
      ('public.standing_guard(text, uuid, uuid)',
       $a$action in ('message_dm', 'dm_open', 'friend', 'join', 'create_server')$a$,
       $a$action in ('message_dm', 'dm_open', 'friend', 'join', 'create_server', 'react')$a$,
       $a$'create_server', 'react')$a$, 1),
      ('public.username_holds_guard()',
       $a$raise exception 'That username is taken' using errcode = 'check_violation';$a$,
       $a$raise exception 'That username is taken for now: it was just let go and is held until % UTC.',
      (select to_char(max(h.until) at time zone 'UTC', 'YYYY-MM-DD HH24:MI') from public.username_holds h where h.name_key = k_new)
      using errcode = 'check_violation';$a$,
       'is held until', 2)    -- the INSERT and the UPDATE branch, both on purpose
    ) v(fn, anchor, replacement, marker, expect)
  loop
    d := pg_get_functiondef(p.fn::regprocedure);
    continue when position(p.marker in d) > 0;          -- already patched
    -- replace() hits every copy of the line, so the count has to be what was read from the live text.
    n_hits := (length(d) - length(replace(d, p.anchor, ''))) / length(p.anchor);
    if n_hits <> p.expect then raise exception '% changed: expected the line to patch % time(s), found %. Read its live text again', p.fn, p.expect, n_hits; end if;
    n := replace(d, p.anchor, p.replacement);
    execute n;
  end loop;
end $$;

-- ---------- 2: promote channel ----------

-- One row per server that was promoted: a server can be promoted once per 6 hours, whoever posts it.
create table if not exists public.promo_invite_marks (
  server_id uuid primary key references public.servers (id) on delete cascade,
  at timestamptz not null default now()
);
alter table public.promo_invite_marks enable row level security;
revoke all on public.promo_invite_marks from public, anon, authenticated;

-- Live text (Oct 21, from 202) with the invite checks added after the #promote-your-server name check.
create or replace function public.invites_only_in_promo()
returns trigger language plpgsql security definer set search_path = public as $$
declare ch record; last_at timestamptz; mark timestamptz; icode text; sid uuid; sids uuid[] := '{}'; nlinks int; ncodes int := 0;
begin
  if new.content !~* '(yapper\.website/invite/|discord\.gg/|discord(app)?\.com/invite/|t\.me/|guilded\.gg/)' then return new; end if;
  -- An edit that keeps the same invite links (fixing the text around them) isn't a new invite post.
  if tg_op = 'UPDATE' and not exists (
       select 1 from regexp_matches(new.content, '(?:yapper\.website/invite/|discord\.gg/|discord(?:app)?\.com/invite/|t\.me/|guilded\.gg/)[^\s<>()]*', 'gi') n
       where lower(n[1]) not in (
         select lower(o[1]) from regexp_matches(coalesce(old.content, ''), '(?:yapper\.website/invite/|discord\.gg/|discord(?:app)?\.com/invite/|t\.me/|guilded\.gg/)[^\s<>()]*', 'gi') o)) then
    return new;
  end if;
  select c.name, c.server_id into ch from public.channels c where c.id = new.channel_id;
  if ch.server_id is null or ch.server_id <> (select default_server_id from public.app_settings limit 1) or public.is_staff() then return new; end if;
  if ch.name !~* 'promot' then
    raise exception 'Invite links only go in #promote-your-server.' using errcode = 'check_violation';
  end if;

  -- Each Yapper invite: a real one, for a live server you are in, not promoted in the last 6 hours.
  nlinks := (select count(*) from regexp_matches(new.content, 'yapper\.website/invite/', 'gi'));
  for icode in select m[1] from regexp_matches(new.content, 'yapper\.website/invite/([A-Za-z0-9_-]+)', 'gi') m loop
    ncodes := ncodes + 1;
    select i.server_id into sid from public.invites i where lower(i.code) = lower(icode) limit 1;
    if sid is null then
      raise exception 'That Yapper invite link doesn''t work. Copy a fresh one from your server.' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.servers s where s.id = sid and s.shut_down_at is not null) then
      raise exception 'That server can''t be promoted.' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = new.author_id) then
      raise exception 'You can only promote a server you are in.' using errcode = 'check_violation';
    end if;
    sids := sids || sid;
  end loop;
  -- A link whose code isn't plain letters, numbers, _ or - (a percent-encoded one, say) can't be checked: refuse it.
  if ncodes <> nlinks then
    raise exception 'That Yapper invite link doesn''t work. Copy a fresh one from your server.' using errcode = 'check_violation';
  end if;
  -- One server, once per 6 hours, whoever posts it. The lock (taken in a fixed order) makes two accounts posting the
  -- same server at the same moment wait for each other instead of both passing.
  for sid in select distinct s from unnest(sids) s order by 1 loop
    perform pg_advisory_xact_lock(hashtextextended('promo:' || sid::text, 0));
    if exists (select 1 from public.promo_invite_marks pm where pm.server_id = sid and pm.at > now() - interval '6 hours') then
      raise exception 'That server was already promoted in the last 6 hours. Try again later.' using errcode = 'check_violation';
    end if;
  end loop;

  select max(m.created_at) into last_at from public.messages m
    where m.channel_id = new.channel_id and m.author_id = new.author_id and m.id <> new.id
      and m.created_at > now() - interval '6 hours'
      and m.content ~* '(yapper\.website/invite/|discord\.gg/|discord(app)?\.com/invite/|t\.me/|guilded\.gg/)';
  select at into mark from public.post_marks where channel_id = new.channel_id and author_id = new.author_id and kind = 'invite' and at > now() - interval '6 hours';
  last_at := greatest(last_at, mark);
  if last_at is not null then
    raise exception 'You can post an invite in #promote-your-server once every 6 hours. Next one in % min', greatest(1, ceil(extract(epoch from (last_at + interval '6 hours' - now())) / 60)) using errcode = 'check_violation';
  end if;
  insert into public.post_marks (channel_id, author_id, kind, at) values (new.channel_id, new.author_id, 'invite', now())
    on conflict (channel_id, author_id, kind) do update set at = excluded.at;
  if cardinality(sids) > 0 then
    insert into public.promo_invite_marks (server_id, at) select distinct s, now() from unnest(sids) s order by 1
      on conflict (server_id) do update set at = excluded.at;
  end if;
  return new;
end $$;
revoke execute on function public.invites_only_in_promo() from public, anon, authenticated;

-- ---------- 3: reactions ----------

create or replace function public.reaction_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  -- The system and the paths that set yapper.bot skip it; staff skip it too (checked only when a refusal is coming).
  if auth.uid() is null or coalesce(current_setting('yapper.bot', true), '') = '1' then return new; end if;
  -- Site timeout (profiles.muted_until), the same one message_automod enforces for messages.
  if exists (select 1 from public.profiles p where p.id = new.user_id and p.muted_until > now()) then
    if public.is_staff() then return new; end if;
    raise exception 'You are timed out, so you can''t react right now.' using errcode = 'insufficient_privilege';
  end if;
  -- Server timeout, the same one block_server_timeouts enforces for messages in that server.
  select c.server_id into sid from public.messages m join public.channels c on c.id = m.channel_id where m.id = new.message_id;
  if sid is not null and exists (select 1 from public.server_timeouts t where t.server_id = sid and t.user_id = new.user_id and t.until > now()) then
    if public.is_staff() then return new; end if;
    raise exception 'You are timed out in this server, so you can''t react right now.' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
revoke execute on function public.reaction_guard() from public, anon, authenticated;

create or replace trigger reactions_guard before insert on public.reactions
  for each row execute function public.reaction_guard();

reset lock_timeout;
