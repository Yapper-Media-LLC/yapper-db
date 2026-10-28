-- 202: bug batch (Oct 17). Re-runnable. Function bodies are the LIVE definitions (pg_get_functiondef, Oct 17),
-- not older repo files: several were patched in place on the live database.
--
-- 1. Slowmode bypass by editing: message_slowmode() only runs on insert, so people "chatted" by editing one message.
--    New trigger messages_edit_slowmode (message_edit_slowmode()): in a channel with slowmode, a content edit by
--    someone without Manage Messages waits min(slowmode, 15 min) since their last edit there (post_marks kind 'edit').
--    The first edit within 2 minutes of posting is free (typo fixes). Bots (yapper.bot = '1') and the service role skip.
-- 2. invites_only_in_promo(): an edit that keeps the same invite links isn't a new invite post (editing your own
--    #promote-your-server post within 6 h always failed). Editing in a NEW invite still follows the 6 h rule.
-- 3. HQ #promote-your-server: slowmode 3600 -> 21600, so the chip says what the invite rule enforces (6 h).
-- 4. no_images_channel(): media file endings only count inside a link (https://...x.gif), not a bare ".gif" in text.
-- 5. bot_webhooks(): message events carry author_bot (author is a bot account, or the message came from a webhook),
--    so bots can skip other bots (the SDK does by default) and two bots can't ping-pong forever.
-- 6. send_friend_request(): bots can't be friended ("Bots can't be friends"). Existing pending rows are left alone.
-- 7. join_default_server(): bot accounts (user_metadata.bot = true from app/api/bots) don't auto-join Yapper HQ.
--    Existing memberships are left alone.
-- 8. unread_counts_v2(): a reply to one of my messages counts as a mention in the @ badge (same structure as 199;
--    one primary-key lookup per unread reply, only among the <= 100 rows the lateral already reads).

-- ---------- 1. slowmode on edits ----------
create or replace function public.message_edit_slowmode()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare c public.channels; me uuid := auth.uid(); slow int; mark timestamptz; wait int;
begin
  if new.content is not distinct from old.content then return new; end if;
  if coalesce(current_setting('yapper.bot', true), '') = '1' or me is null then return new; end if;
  select * into c from public.channels where id = old.channel_id;
  if c.server_id is null then return new; end if;
  slow := least(greatest(coalesce(c.slowmode, 0), case when c.auto_slow_until > now() then 5 else 0 end), 900);
  if slow <= 0 then return new; end if;
  -- A quick fix right after posting is free.
  if old.edited_at is null and old.created_at > now() - interval '2 minutes' then return new; end if;
  if public.channel_allows(c.id, 'manage_messages') then return new; end if;
  perform pg_advisory_xact_lock(hashtext('slowedit:' || me::text || ':' || c.id::text));
  select at into mark from public.post_marks where channel_id = c.id and author_id = me and kind = 'edit';
  if mark is not null and mark > now() - make_interval(secs => slow) then
    wait := greatest(1, ceil(extract(epoch from (mark + make_interval(secs => slow) - now()))));
    raise exception 'Slowmode is on. You can edit again in %s', wait using errcode = 'P0001';
  end if;
  insert into public.post_marks (channel_id, author_id, kind, at) values (c.id, me, 'edit', now())
    on conflict (channel_id, author_id, kind) do update set at = excluded.at;
  return new;
end $function$;
revoke all on function public.message_edit_slowmode() from public, anon;
grant execute on function public.message_edit_slowmode() to authenticated, service_role;

-- Runs after messages_edit_guard (triggers fire in name order), so a timed-out edit is refused there first.
create or replace trigger messages_edit_slowmode
  before update of content on public.messages
  for each row when (new.content is distinct from old.content)
  execute function public.message_edit_slowmode();

-- ---------- 2. invites in #promote-your-server: edits keep their invite ----------
create or replace function public.invites_only_in_promo()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare ch record; last_at timestamptz; mark timestamptz;
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
  return new;
end $function$;

-- ---------- 3. HQ #promote-your-server slowmode matches the 6 h invite rule ----------
update public.channels c set slowmode = 21600
 where c.server_id = (select default_server_id from public.app_settings limit 1)
   and c.name = 'promote-your-server'
   and c.slowmode is distinct from 21600;

-- ---------- 4. text-only channels: only links count as media ----------
create or replace function public.no_images_channel()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare c public.channels; hq uuid;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null or not c.no_images then return new; end if;
  if public.channel_allows(c.id, 'manage_messages') then return new; end if;
  select default_server_id into hq from public.app_settings limit 1;
  -- Yapper HQ only: Yapper Plus members can post media in text-only channels.
  if c.server_id = hq and exists (select 1 from public.profiles p where p.id = new.author_id and p.plus_until > now()) then return new; end if;
  if new.attachment_path is not null
     or new.content ~* 'https?://\S+\.(png|jpe?g|gif|webp|avif|mp4|webm|mov|mp3|ogg|wav|m4a)(?![a-z0-9])'
     or new.content ~* '(tenor\.com|giphy\.com|klipy\.com|imgur\.com|media\.discordapp\.net|cdn\.discordapp\.com)/' then
    if c.server_id = hq then
      raise exception 'Media goes in #media here. Yapper Plus members can post it in any channel.' using errcode = 'check_violation';
    end if;
    raise exception 'This channel is text only. Images and GIFs go in an images channel.' using errcode = 'check_violation';
  end if;
  return new;
end; $function$;

-- ---------- 5. bot message events say whether the author is a bot ----------
do $do$
declare
  d text := pg_get_functiondef('public.bot_webhooks()'::regprocedure);
  a text := $a$'reply_to_id', new.reply_to_id, 'created_at', new.created_at);$a$;
  b text := $b$'reply_to_id', new.reply_to_id, 'created_at', new.created_at,
    'author_bot', new.webhook is not null or public.is_bot_user(new.author_id));$b$;
begin
  if strpos(d, '''author_bot''') > 0 then return; end if;
  if strpos(d, a) = 0 then raise exception '202: bot_webhooks() changed on the live database, anchor not found'; end if;
  execute replace(d, a, b);
end $do$;

-- ---------- 6. no friend requests to bots ----------
do $do$
declare
  d text := pg_get_functiondef('public.send_friend_request(text, text)'::regprocedure);
  a text := $a$  if target = me then raise exception 'You can''t friend yourself (we checked)'; end if;$a$;
  b text := $b$  if target = me then raise exception 'You can''t friend yourself (we checked)'; end if;
  if public.is_bot_user(target) then raise exception 'Bots can''t be friends' using errcode = 'check_violation'; end if;$b$;
begin
  if strpos(d, 'Bots can''''t be friends') > 0 then return; end if;
  if strpos(d, a) = 0 then raise exception '202: send_friend_request() changed on the live database, anchor not found'; end if;
  execute replace(d, a, b);
end $do$;

-- ---------- 7. bot accounts don't auto-join Yapper HQ ----------
create or replace function public.join_default_server()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  sid uuid := (select default_server_id from public.app_settings where id);
begin
  if sid is null then return new; end if;
  -- Bot accounts (app/api/bots makes them with user_metadata.bot = true, before their bots row exists).
  if exists (select 1 from auth.users u where u.id = new.id and coalesce(u.raw_user_meta_data ->> 'bot', '') = 'true')
     or public.is_bot_user(new.id) then
    return new;
  end if;
  insert into public.server_members (server_id, user_id) values (sid, new.id) on conflict do nothing;
  return new;
end;
$function$;

-- ---------- 8. replies to me count as mentions ----------
create or replace function public.unread_counts_v2()
returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with pings as materialized (select * from public.my_role_pings()),
  vc as materialized (
    select f.mode, f.servers, f.users from public.feature_flags f where f.key = 'voice_chat'
  ),
  mine as materialized (
    select cm.channel_id, cm.joined_at as since, null::uuid as sid from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at, c.server_id from public.my_visible_server_channels() c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text'
       or (c.kind = 'voice' and exists (select 1 from vc where vc.mode = 'everyone'
             or (vc.mode = 'test' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users))))
             and (not public.channel_overrides_live(c.id) or public.channel_perm(c.id, 'connect')))
  )
  select
    mine.channel_id,
    coalesce(x.unread, 0),
    coalesce(r.muted, false),
    coalesce(x.mentions, 0)
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid()
  left join pings p on p.sid = mine.sid
  left join lateral (
    select count(*)::int as unread,
           (count(*) filter (where f.content like '%<@' || auth.uid()::text || '>%'
                              or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
                              or (p.pats is not null and strpos(f.content, '<@&') > 0 and f.content like any (p.pats))
                              or (f.reply_to_id is not null
                                  and exists (select 1 from public.messages pm where pm.id = f.reply_to_id and pm.author_id = (select auth.uid())))))::int as mentions
    from (
      select m.content, m.reply_to_id from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > coalesce(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) f
  ) x on true;
$function$;

notify pgrst, 'reload schema';

-- server_timed_out(sid, uid) was callable signed-out (anon): no reason for that. Signed-in callers keep it
-- (the mod menus use it to show "Remove timeout" only for people who are timed out).
revoke execute on function public.server_timed_out(uuid, uuid) from public, anon;
grant execute on function public.server_timed_out(uuid, uuid) to authenticated, service_role;
