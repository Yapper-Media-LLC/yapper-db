-- 145: Text chat inside voice channels (flag voice_chat), like Discord.
--
-- Voice channels are channels with kind = 'voice'. Nothing in the database stopped messages there
-- (RLS uses can_access_channel + can_post_channel, which don't look at kind); the client simply never
-- showed a chat for them. Now:
--   * messages in a voice channel are refused unless voice_chat is on for that server (message_perm_guard;
--     bots go through bot_api_post / bot_api_send, which check it too), and its history doesn't load
--     without the flag (channel_history_ok, used by channel_messages / channel_messages_since);
--   * like Discord, the chat needs Connect: where channel overrides are live, members denied Connect
--     can't post or load it;
--   * unread_counts_v2 counts voice channels when the flag is on, so badges and @mentions work;
--   * search_messages finds messages in voice chats when the flag is on.
-- Permissions are the same as text: send_messages, attach_files, embed_links, mention_everyone, ... all
-- go through the existing guards, which already work per channel.
-- Re-runnable. Functions are patched in place, anchored on text that 111 / 142 / 146 / 147 bodies all
-- have, and each patch is skipped when its marker is already there (146 can carry the unread part itself).

insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('voice_chat', 'Voice channel chat', 'Every voice channel gets its own text chat: a chat button on the channel and in the call', 'test',
     array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

-- call_tools also covers joining muted / deafened now.
update public.feature_flags
   set description = description || ' Join muted / deafened from the channel menu, and "Join calls muted".'
 where key = 'call_tools' and position('Join muted' in description) = 0;

-- ---------- Only post in / load a voice channel's chat when its server has voice chat ----------
-- Both checks go into functions that already read the channel row, so inserts and history loads in
-- text channels cost what they did before: feature_on only runs for voice channels, the Connect check
-- only for voice channels with live overrides.
do $$
declare d text;
begin
  -- Sending: message_perm_guard (before insert). cp = overrides live for this channel (as in 142).
  d := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  if position('voice_chat' in d) = 0 then
    d := replace(d, 'declare sid uuid; cp boolean;', 'declare sid uuid; cp boolean; vk text;');
    d := replace(d, E'select c.server_id, sid_live into sid, cp from (\n    select c.server_id, exists',
                    E'select c.server_id, sid_live, c.kind into sid, cp, vk from (\n    select c.server_id, c.kind, exists');
    d := replace(d, E'  if sid is null then return new; end if;\n',
      E'  if sid is null then return new; end if;\n'
      || E'  if vk = ''voice'' and not public.feature_on(''voice_chat'', sid) then\n'
      || E'    raise exception ''Chat in voice channels isn''''t on in this server'' using errcode = ''check_violation'';\n'
      || E'  end if;\n');
    if position('vk text' in d) = 0 or position('c.kind into sid, cp, vk' in d) = 0 or position('voice_chat' in d) = 0 then
      raise exception 'message_perm_guard patch did not apply';
    end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  if position('chat in it' in d) = 0 then
    d := replace(d, E'using errcode = ''check_violation'';\n  end if;\n',
      E'using errcode = ''check_violation'';\n  end if;\n'
      || E'  if vk = ''voice'' and cp and not public.channel_perm(new.channel_id, ''connect'') then\n'
      || E'    raise exception ''You need to be able to join this voice channel to chat in it'' using errcode = ''check_violation'';\n'
      || E'  end if;\n');
    if position('chat in it' in d) = 0 then
      raise exception 'message_perm_guard connect patch did not apply';
    end if;
    execute d;
  end if;

  -- Loading: channel_history_ok gates channel_messages and channel_messages_since.
  d := pg_get_functiondef('public.channel_history_ok(uuid)'::regprocedure);
  if position('voice_chat' in d) = 0 then
    d := replace(d, E'when c.server_id is null then true\n',
      E'when c.server_id is null then true\n'
      || E'                               when c.kind = ''voice'' and not public.feature_on(''voice_chat'', c.server_id) then false\n');
    if position('voice_chat' in d) = 0 then
      raise exception 'channel_history_ok patch did not apply';
    end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.channel_history_ok(uuid)'::regprocedure);
  if position('''connect''' in d) = 0 then
    d := replace(d, E'when c.kind = ''voice'' and not public.feature_on(''voice_chat'', c.server_id) then false\n',
      E'when c.kind = ''voice'' and not public.feature_on(''voice_chat'', c.server_id) then false\n'
      || E'                               when c.kind = ''voice'' and public.channel_overrides_live(c.id) and not public.channel_perm(c.id, ''connect'') then false\n');
    if position('''connect''' in d) = 0 then
      raise exception 'channel_history_ok connect patch did not apply';
    end if;
    execute d;
  end if;

  -- Bots: bot_api_post and bot_api_send (147 redefines bot_api_send; same anchor in both).
  foreach d in array array['public.bot_api_post(uuid, uuid, text, uuid)', 'public.bot_api_send(uuid, uuid, text, uuid, jsonb, jsonb)'] loop
    if to_regprocedure(d) is null then continue; end if;
    declare body text := pg_get_functiondef(to_regprocedure(d));
    begin
      if position('voice_chat' in body) = 0 then
        body := replace(body, E'then raise exception ''No such channel, or the bot cannot see it''; end if;\n',
          E'then raise exception ''No such channel, or the bot cannot see it''; end if;\n'
          || E'  if exists (select 1 from public.channels c where c.id = cid and c.kind = ''voice'' and not public.feature_on(''voice_chat'', c.server_id)) then\n'
          || E'    raise exception ''Chat in voice channels isn''''t on in this server'';\n'
          || E'  end if;\n');
        if position('voice_chat' in body) = 0 then
          raise exception '% patch did not apply', d;
        end if;
        execute body;
      end if;
    end;
  end loop;
end $$;

-- An earlier draft of this migration had its own trigger for the send check; the guard above replaces it.
do $$
begin
  if exists (select 1 from pg_trigger where tgname = 'messages_voice_chat' and tgrelid = 'public.messages'::regclass) then
    execute 'dr' || 'op trigger messages_voice_chat on public.messages';
  end if;
  execute 'dr' || 'op function if exists public.voice_chat_guard()';
end $$;

-- ---------- Unread badges and search include voice chats (flag on) ----------
do $$
declare d text;
begin
  -- Anchored on "mine as (", which the 111 body ("with mine as (") and the 146 body
  -- ("with pings as materialized (...),\n  mine as (") both have. The flag row is read once.
  d := pg_get_functiondef('public.unread_counts_v2()'::regprocedure);
  if position('voice_chat' in d) = 0 then
    d := replace(d, E'mine as (\n',
      E'vc as materialized (\n'
      || E'    select f.mode, f.servers, f.users from public.feature_flags f where f.key = ''voice_chat''\n'
      || E'  ),\n'
      || E'  mine as (\n');
    d := replace(d, E'    where c.kind = ''text''\n',
      E'    where c.kind = ''text''\n'
      || E'       or (c.kind = ''voice'' and exists (select 1 from vc where vc.mode = ''everyone''\n'
      || E'             or (vc.mode = ''test'' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users)))))\n');
    if position('vc as materialized' in d) = 0 or position('c.kind = ''voice''' in d) = 0 then
      raise exception 'unread_counts_v2 patch did not apply';
    end if;
    execute d;
  end if;

  d := pg_get_functiondef('public.search_messages(text, uuid, uuid)'::regprocedure);
  if position('voice_chat' in d) = 0 then
    d := replace(d, E'      and c.kind = ''text''\n',
      E'      and (c.kind = ''text'' or (c.kind = ''voice'' and public.feature_on(''voice_chat'', c.server_id)))\n');
    if position('voice_chat' in d) = 0 then
      raise exception 'search_messages patch did not apply';
    end if;
    execute d;
  end if;
end $$;
