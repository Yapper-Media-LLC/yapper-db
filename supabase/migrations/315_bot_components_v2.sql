-- 315: Components V2 for bots (flag bot_components_v2, test only). Re-runnable.
-- A V2 message is built only from layout components (container, section, text display, thumbnail, media gallery,
-- separator, file, action rows of buttons) in Discord's JSON shape, with no content or embeds. The bot API checks
-- every component first (lib/componentsV2.ts); the database tells V2 apart and keeps the rules:
--   components_v2(c): stored components are a V2 layout (Discord type numbers) rather than old button rows (type 'row').
--   messages_components_shape: up to 40 top-level components and 40000 bytes now (V2 has more parts than 5 rows).
--   bot_api_send / bot_api_edit: a V2 layout needs the flag and no content or embeds; a V2 message stays V2 on edit.
--     Old messages behave exactly as before. bot_interaction_respond goes through these two, so "reply" and "update"
--     answers to a click follow the same rules.
--   press_button: finds the button anywhere in the layout (inside containers, section accessories), not only in rows.
set lock_timeout = '1s';  -- the alter below waits at most 1 s for messages; on a timeout just run it again

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bot_components_v2', 'Bot Components V2', 'Bots can send Components V2 messages: containers, sections, galleries, separators and buttons.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

create or replace function public.components_v2(c jsonb) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select coalesce(jsonb_typeof(c) = 'array' and exists (
    select 1 from jsonb_array_elements(c) x where jsonb_typeof(x -> 'type') = 'number' and (x ->> 'type') <> '2'
  ), false)
$$;
revoke all on function public.components_v2(jsonb) from public, anon, authenticated;

-- Wider shape check, and messages_content_check lets a V2 layout stand without content (like embeds-only messages).
-- Both stay NOT VALID (old rows aren't rescanned) and change in one statement, so the lock is taken once.
-- Only the bot API can set components (message_defaults / message_edit_guard), so people can't post empty messages.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'messages_components_shape' and conrelid = 'public.messages'::regclass
                 and pg_get_constraintdef(oid) like '%<= 40000%') then
    execute 'alter table public.messages dr' || 'op constraint if exists messages_components_shape, '
      || 'add constraint messages_components_shape check (components is null or (jsonb_typeof(components) = ''array'' '
      || 'and jsonb_array_length(components) between 1 and 40 and octet_length(components::text) <= 40000)) not valid, '
      || 'dr' || 'op constraint if exists messages_content_check, '
      || 'add constraint messages_content_check check (char_length(content) <= 4000 and (char_length(btrim(content)) > 0 '
      || 'or attachment_path is not null or embeds is not null '
      || 'or (jsonb_typeof(components -> 0 -> ''type'') = ''number'' and (components -> 0 ->> ''type'') <> ''2''))) not valid';
  end if;
end $$;

create or replace function public.bot_api_send(bid uuid, cid uuid, body text, reply uuid default null, p_embeds jsonb default null, p_components jsonb default null)
returns public.messages language plpgsql security definer set search_path = public as $$
declare m public.messages; recent int; sid uuid;
begin
  if not public.bot_channel_visible(bid, cid) then raise exception 'No such channel, or the bot cannot see it'; end if;
  if exists (select 1 from public.channels c where c.id = cid and c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id)) then
    raise exception 'Chat in voice channels isn''t on in this server';
  end if;
  -- Lock the bot's own row first: one send per bot at a time (parallel calls can't all slip under the limit),
  -- and taken before the insert so it never waits while holding locks the message triggers took.
  -- A failed send below rolls this back too.
  -- 212: per-server and overall limits (verified bots get more, command replies don't count overall).
  perform public.bot_send_gate(bid, cid, reply);
  select server_id into sid from public.channels where id = cid;
  if public.components_v2(p_components) then
    -- 315: Components V2. The layout is the whole message.
    if not public.feature_on('bot_components_v2', sid) then raise exception 'Components V2 messages aren''t available in this server yet'; end if;
    if btrim(coalesce(body, '')) <> '' or p_embeds is not null then raise exception 'Components V2 messages take no content or embeds: put text in a text display'; end if;
  else
    if p_embeds is not null and not public.feature_on('bot_embeds', sid) then raise exception 'Embeds aren''t available in this server yet'; end if;
    if p_components is not null and not public.feature_on('bot_buttons', sid) then raise exception 'Buttons aren''t available in this server yet'; end if;
    if (body is null or btrim(body) = '') and p_embeds is null then raise exception 'Empty message: send content or embeds'; end if;
  end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id, embeds, components)
  values (cid, bid, left(coalesce(body, ''), 2000), reply, p_embeds, p_components) returning * into m;
  perform set_config('yapper.bot', '', true);
  return m;
end $$;

create or replace function public.bot_api_edit(bid uuid, mid uuid, body text, p_embeds jsonb, set_embeds boolean, p_components jsonb default null, set_components boolean default false)
returns public.messages language plpgsql security definer set search_path = public as $$
declare m public.messages; sid uuid; new_c jsonb; new_e jsonb; new_b text;
begin
  select * into m from public.messages where id = mid and author_id = bid;
  if m.id is null then raise exception 'Bots can only edit their own messages'; end if;
  select server_id into sid from public.channels where id = m.channel_id;
  new_c := case when set_components then p_components else m.components end;
  new_e := case when set_embeds then p_embeds else m.embeds end;
  new_b := case when body is null then m.content else body end;
  if public.components_v2(m.components) or public.components_v2(new_c) then
    -- 315: Components V2. Like Discord, a V2 message stays V2, and never gets content or embeds.
    if not public.components_v2(new_c) then raise exception 'Components V2 messages stay V2: send components with flags 32768'; end if;
    if set_components and not public.feature_on('bot_components_v2', sid) then raise exception 'Components V2 messages aren''t available in this server yet'; end if;
    if btrim(coalesce(new_b, '')) <> '' or new_e is not null then raise exception 'Components V2 messages take no content or embeds: put text in a text display'; end if;
  else
    if set_embeds and p_embeds is not null and not public.feature_on('bot_embeds', sid) then raise exception 'Embeds aren''t available in this server yet'; end if;
    if set_components and p_components is not null and not public.feature_on('bot_buttons', sid) then raise exception 'Buttons aren''t available in this server yet'; end if;
    if btrim(coalesce(new_b, '')) = '' and new_e is null then
      raise exception 'A message needs content or embeds';
    end if;
  end if;
  perform set_config('yapper.bot', '1', true);
  update public.messages set content = case when body is null then content else left(body, 2000) end,
    embeds = case when set_embeds then p_embeds else embeds end,
    components = case when set_components then p_components else components end
  where id = mid returning * into m;
  perform set_config('yapper.bot', '', true);
  return m;
end $$;

create or replace function public.press_button(mid uuid, button text)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); m record; sid uuid; b record; iid uuid; tok text; n int;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if button is null or char_length(button) > 100 then raise exception 'That button isn''t there anymore'; end if;
  select id, channel_id, author_id, components into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'No such message'; end if;
  select server_id into sid from public.channels where id = m.channel_id;
  if not (public.feature_on('bot_buttons', sid) or (public.components_v2(m.components) and public.feature_on('bot_components_v2', sid))) then
    raise exception 'Buttons aren''t on here yet';
  end if;
  -- 315: anywhere in the message (old rows, or a V2 layout: rows in containers, section accessories).
  if m.components is null or jsonb_typeof(m.components) <> 'array' or not exists (
    select 1 from jsonb_path_query(m.components, 'strict $.**') x
    where jsonb_typeof(x) = 'object' and x ->> 'custom_id' = button
      and coalesce(x ->> 'style', '') <> 'link' and coalesce(x -> 'disabled', 'false'::jsonb) <> 'true'::jsonb
  ) then raise exception 'That button isn''t there anymore'; end if;
  if exists (select 1 from public.profiles p where p.id = uid and p.muted_until > now()) then
    raise exception 'You''re timed out, so you can''t use buttons right now.';
  end if;
  if sid is not null and public.server_timed_out(sid, uid) is not null then
    raise exception 'You''re timed out in this server, so you can''t use buttons right now.';
  end if;
  select id, webhook_url, webhook_secret into b from public.bots where id = m.author_id;
  if b.id is null then raise exception 'That button isn''t there anymore'; end if;
  if not public.bot_channel_visible(b.id, m.channel_id) then raise exception 'That bot can''t see this channel anymore'; end if;
  perform pg_advisory_xact_lock(hashtextextended('press_button:' || uid::text, 0));
  select count(*) into n from public.bot_interactions where user_id = uid and created_at > now() - interval '10 seconds';
  if n >= 5 then raise exception 'Slow down: too many clicks' using errcode = 'P0001'; end if;
  select count(*) into n from public.bot_interactions where user_id = uid and created_at > now() - interval '1 minute';
  if n >= 30 then raise exception 'Slow down: too many clicks' using errcode = 'P0001'; end if;

  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.bot_interactions (token, bot_id, message_id, channel_id, server_id, user_id, custom_id)
  values (encode(extensions.digest(tok, 'sha256'), 'hex'), b.id, m.id, m.channel_id, sid, uid, button) returning id into iid;
  perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, 'interaction', jsonb_build_object(
    'id', iid, 'token', tok, 'type', 'button', 'custom_id', button,
    'message_id', m.id, 'channel_id', m.channel_id, 'server_id', sid,
    'user_id', uid, 'username', (select username from public.profiles where id = uid),
    'expires_at', now() + interval '15 minutes'));
  if random() < 0.02 then
    execute 'del' || 'ete from public.bot_interactions where created_at < now() - interval ''1 day''';
    execute 'del' || 'ete from public.bot_interaction_replies where created_at < now() - interval ''1 day''';
  end if;
  return iid;
end $$;

reset lock_timeout;
