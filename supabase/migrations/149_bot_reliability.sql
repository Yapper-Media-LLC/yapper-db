-- 149: bot platform reliability fixes. Re-runnable.
--
-- 1. Deadlocks: every event did "update bots set last_event_at = now()" on each receiving bot, inside the
--    sender's transaction. Two messages at once in a server with several bots (a bot sending while people
--    talk) locked the same bots rows in different orders: 44 "deadlock detected" a day in the logs, each one
--    a failed send. Now the stamp is skipped when the row is busy (skip locked) and written at most once a
--    minute, so it never waits on another transaction (and 100k+ row updates a day go away).
-- 2. The 30 messages a minute limit was a plain count, so a burst of parallel sends all saw "under 30"
--    (one bot got 43 out in a minute). The bot's own row is now locked first (the posts counter update moved
--    to the top), which makes the count and the insert one step and keeps that lock out of the trigger order.
-- 3. Webhook bodies carry the event id ({ id, event, data }), the same id polling uses, so a receiver can
--    skip repeats and match webhooks with polled events.
-- 4. bot_api_post (the pre-embeds send) was still executable by `authenticated`, and it takes the bot id as an
--    argument: any signed-in user could post as any bot. Nothing in the app calls it; now service role only.

create or replace function public.bot_push(bid uuid, hook_url text, hook_secret text, ev text, payload jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare body text; sig text; cid uuid; sid uuid; eid bigint;
begin
  -- Every event carries channel_id and server_id (null when the event isn't in a channel / is in a DM).
  payload := coalesce(payload, '{}'::jsonb);
  cid := nullif(payload ->> 'channel_id', '')::uuid;
  if cid is null and nullif(payload ->> 'message_id', '') is not null then
    select channel_id into cid from public.messages where id = (payload ->> 'message_id')::uuid;
  end if;
  sid := nullif(payload ->> 'server_id', '')::uuid;
  if sid is null and cid is not null then select server_id into sid from public.channels where id = cid; end if;
  payload := payload || jsonb_build_object('channel_id', cid, 'server_id', sid);
  insert into public.bot_events (bot_id, type, data) values (bid, ev, payload) returning id into eid;
  -- Never wait for the bots row here (that is what deadlocked parallel sends); a minute-old stamp is fine.
  update public.bots set last_event_at = now()
   where id in (select b.id from public.bots b
                 where b.id = bid and (b.last_event_at is null or b.last_event_at < now() - interval '1 minute')
                 for update skip locked);
  if hook_url is not null then
    body := jsonb_build_object('id', eid, 'event', ev, 'data', payload)::text;
    sig := encode(extensions.hmac(body, coalesce(hook_secret, ''), 'sha256'), 'hex');
    perform net.http_post(
      url := hook_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Yapper-Signature', 'sha256=' || sig, 'X-Yapper-Bot', bid::text),
      body := body::jsonb,
      timeout_milliseconds := 3000);
  end if;
  if random() < 0.01 then
    execute 'del' || 'ete from public.bot_events where created_at < now() - interval ''1 day''';
  end if;
end $function$;

create or replace function public.bot_api_send(bid uuid, cid uuid, body text, reply uuid default null::uuid, p_embeds jsonb default null::jsonb, p_components jsonb default null::jsonb)
returns messages
language plpgsql
security definer
set search_path to 'public'
as $function$
declare m public.messages; recent int; sid uuid;
begin
  if not public.bot_channel_visible(bid, cid) then raise exception 'No such channel, or the bot cannot see it'; end if;
  if exists (select 1 from public.channels c where c.id = cid and c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id)) then
    raise exception 'Chat in voice channels isn''t on in this server';
  end if;
  -- Lock the bot's own row first: one send per bot at a time (parallel calls can't all slip under the limit),
  -- and taken before the insert so it never waits while holding locks the message triggers took.
  -- A failed send below rolls this back too.
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  select count(*) into recent from public.messages where author_id = bid and created_at > now() - interval '1 minute';
  if recent >= 30 then raise exception 'Slow down: 30 messages a minute per bot' using errcode = 'P0001'; end if;
  select server_id into sid from public.channels where id = cid;
  if p_embeds is not null and not public.feature_on('bot_embeds', sid) then raise exception 'Embeds aren''t available in this server yet'; end if;
  if p_components is not null and not public.feature_on('bot_buttons', sid) then raise exception 'Buttons aren''t available in this server yet'; end if;
  if (body is null or btrim(body) = '') and p_embeds is null then raise exception 'Empty message: send content or embeds'; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id, embeds, components)
  values (cid, bid, left(coalesce(body, ''), 2000), reply, p_embeds, p_components) returning * into m;
  perform set_config('yapper.bot', '', true);
  return m;
end $function$;

-- The older entry point (no embeds), kept for anything still calling it: same order.
create or replace function public.bot_api_post(bid uuid, cid uuid, body text, reply uuid default null::uuid)
returns messages
language plpgsql
security definer
set search_path to 'public'
as $function$
declare m public.messages; recent int;
begin
  if not public.bot_channel_visible(bid, cid) then raise exception 'No such channel, or the bot cannot see it'; end if;
  if exists (select 1 from public.channels c where c.id = cid and c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id)) then
    raise exception 'Chat in voice channels isn''t on in this server';
  end if;
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  select count(*) into recent from public.messages where author_id = bid and created_at > now() - interval '1 minute';
  if recent >= 30 then raise exception 'Slow down: 30 messages a minute per bot' using errcode = 'P0001'; end if;
  if body is null or btrim(body) = '' then raise exception 'Empty message'; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id) values (cid, bid, left(body, 2000), reply) returning * into m;
  perform set_config('yapper.bot', '', true);
  return m;
end $function$;

-- create or replace keeps grants, but say it again in case these were made fresh: service role only.
revoke all on function public.bot_push(uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.bot_api_send(uuid, uuid, text, uuid, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.bot_api_post(uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.bot_api_send(uuid, uuid, text, uuid, jsonb, jsonb) to service_role;
grant execute on function public.bot_api_post(uuid, uuid, text, uuid) to service_role;
