-- 483: embed builder (flag embed_builder, test only). Re-runnable.
-- Asked for by .Autumn in HQ: rules / FAQ posts made of coloured embed boxes with link buttons under them, like
-- Discohook makes for Discord. Webhooks (155) already post embeds; this adds:
--   * link buttons on webhook posts: webhook_send_v2 = webhook_send plus p_components. Only link buttons (style link,
--     https url, a label and/or an emoji, no custom_id), up to 5 rows of 5, in the same {type:'row'} shape bot buttons
--     use, so MessageButtons draws them and press_button never finds anything to press. The API cleans them first
--     (lib/components.ts); webhook_links_ok re-checks the shape here.
--   * posting as a webhook from the app (Edit channel -> Webhooks -> Make a post): webhook_post_member(p_uid, wid, ...)
--     for the API route /api/webhooks/post (service role, after it checked the caller's token and cleaned the body).
--     The caller needs Manage Webhooks in that channel right now (webhook_user_blocked), the webhook's creator must
--     still be in good standing (same as a URL post), and the same rate limits count (5 per 2 s per webhook, 30 a minute
--     per channel, counted by webhook_take_member in its own call first). A lock stops a poster without Manage
--     Messages. No token needed: having Manage Webhooks there is enough, the same people who can see the URL.
--   * webhook_send keeps its signature and behaviour; its body moved into webhook_post (internal, nobody can call it
--     directly) so the three ways in share one set of checks.
-- Flag off: webhook_send_v2 refuses components, webhook_post_member refuses everything.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('embed_builder', 'Embed builder', 'Make a post with embeds and link buttons as a webhook from Edit channel, plus link buttons on webhook URLs', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

/** Link-button rows only: [{type:'row', components:[{type:'button', style:'link', url:'https://..', label?, emoji?}]}]. */
create or replace function public.webhook_links_ok(p jsonb) returns boolean
language plpgsql immutable set search_path = public as $$
declare r jsonb; b jsonb; k text;
begin
  if jsonb_typeof(p) is distinct from 'array' or jsonb_array_length(p) not between 1 and 5 then return false; end if;
  for r in select x from jsonb_array_elements(p) x loop
    if jsonb_typeof(r) is distinct from 'object' or r ->> 'type' is distinct from 'row'
       or jsonb_typeof(r -> 'components') is distinct from 'array' or jsonb_array_length(r -> 'components') not between 1 and 5 then
      return false;
    end if;
    for b in select x from jsonb_array_elements(r -> 'components') x loop
      if jsonb_typeof(b) is distinct from 'object' or b ->> 'type' is distinct from 'button' or b ->> 'style' is distinct from 'link' then return false; end if;
      for k in select jsonb_object_keys(b) loop
        if k not in ('type', 'style', 'url', 'label', 'emoji') then return false; end if;
      end loop;
      if jsonb_typeof(b -> 'url') is distinct from 'string' or (b ->> 'url') !~ '^https://[^\s@/]+' or char_length(b ->> 'url') > 512 then return false; end if;
      if b ? 'label' and (jsonb_typeof(b -> 'label') is distinct from 'string' or char_length(b ->> 'label') > 80) then return false; end if;
      if b ? 'emoji' and (jsonb_typeof(b -> 'emoji') is distinct from 'string' or char_length(b ->> 'emoji') > 80) then return false; end if;
      if coalesce(b ->> 'label', '') = '' and coalesce(b ->> 'emoji', '') = '' then return false; end if;
    end loop;
  end loop;
  return true;
end $$;
revoke all on function public.webhook_links_ok(jsonb) from public, anon, authenticated;

/**
 * The shared part of every webhook post (155's webhook_send after its token check), plus link buttons.
 * Internal: only the functions below call it. Errors carry a hint "webhook:<code>" like 155.
 */
create or replace function public.webhook_post(w public.webhooks, body text, p_username text, p_avatar_url text,
  p_embeds jsonb, p_mentions jsonb, p_components jsonb)
returns public.messages language plpgsql security definer set search_path = public as $$
declare
  c record; author uuid; m public.messages; n text; txt text; why text;
  parse jsonb; allow_users jsonb; allow_roles jsonb; r record;
begin
  if w.id is null then raise exception 'Unknown Webhook' using hint = 'webhook:10015'; end if;
  select ch.id, ch.server_id, ch.kind into c from public.channels ch where ch.id = w.channel_id;
  if c.id is null or c.kind is distinct from 'text' then raise exception 'Webhooks only post in text channels' using hint = 'webhook:50001'; end if;
  if not (public.feature_on('webhooks', c.server_id)
          or exists (select 1 from public.feature_flags f where f.key = 'webhooks' and f.mode = 'test' and w.created_by = any(f.users))) then
    raise exception 'Webhooks aren''t on in this server' using hint = 'webhook:50001';
  end if;
  -- The message guards skip bot posts, so the creator's standing is checked here.
  why := public.webhook_user_blocked(w.created_by, c.id);
  if why is not null then
    raise exception 'This webhook can''t post right now: the person who made it is %', why using hint = 'webhook:50001';
  end if;
  if exists (select 1 from public.servers s where s.id = c.server_id and s.shut_down_at is not null) then
    raise exception 'This server is shut down' using hint = 'webhook:50001';
  end if;
  if public.server_locked(c.server_id) and not public.webhook_user_perm(w.created_by, c.id, 'manage_messages') then
    raise exception 'This server is locked by its mods right now' using hint = 'webhook:50001';
  end if;
  select webhook_user_id into author from public.app_settings limit 1;
  if author is null then raise exception 'Webhooks aren''t set up yet' using hint = 'webhook:setup'; end if;

  body := coalesce(body, '');
  if char_length(body) > 2000 then raise exception 'content: Must be 2000 or fewer in length.' using hint = 'webhook:50035'; end if;
  if p_embeds is not null and (jsonb_typeof(p_embeds) <> 'array' or jsonb_array_length(p_embeds) > 10) then
    raise exception 'embeds: Up to 10 embeds' using hint = 'webhook:50035';
  end if;
  if p_embeds is not null and jsonb_array_length(p_embeds) = 0 then p_embeds := null; end if;
  if p_components is not null and jsonb_typeof(p_components) = 'array' and jsonb_array_length(p_components) = 0 then p_components := null; end if;
  if p_components is not null then
    if not (public.feature_on('embed_builder', c.server_id)
            or exists (select 1 from public.feature_flags f where f.key = 'embed_builder' and f.mode = 'test' and w.created_by = any(f.users))) then
      raise exception 'components: Buttons on webhooks aren''t on in this server yet' using hint = 'webhook:50035';
    end if;
    if not public.webhook_links_ok(p_components) then
      raise exception 'components: Webhooks can only send link buttons (https), up to 5 rows of 5' using hint = 'webhook:50035';
    end if;
  end if;
  if btrim(body) = '' and p_embeds is null then raise exception 'Cannot send an empty message' using hint = 'webhook:50006'; end if;
  n := case when btrim(coalesce(p_username, '')) = '' then w.name else public.webhook_name_ok(p_username) end;
  if p_avatar_url is not null and (p_avatar_url !~ '^https://' or char_length(p_avatar_url) > 512) then p_avatar_url := null; end if;

  -- The message triggers check content; the name, the embed text and the button labels / links get the same filters here.
  txt := n;
  if p_embeds is not null then
    txt := txt || ' ' || coalesce((select string_agg(v #>> '{}', ' ')
      from jsonb_path_query(p_embeds, 'strict $.**') v where jsonb_typeof(v) = 'string'), '');
  end if;
  if p_components is not null then
    txt := txt || ' ' || coalesce((select string_agg(v #>> '{}', ' ')
      from jsonb_path_query(p_components, 'strict $.**') v where jsonb_typeof(v) = 'string'), '');
  end if;
  if public.has_slur(txt) then
    raise exception 'That contains a slur, so it wasn''t sent. Keep it respectful.' using hint = 'webhook:200000';
  end if;
  if public.has_adult_link(txt) then raise exception 'Links to that site aren''t allowed on Yapper.' using hint = 'webhook:200000'; end if;
  if public.has_self_harm_incitement(body || ' ' || txt) then
    raise exception 'Telling someone to hurt themselves isn''t allowed on Yapper.' using hint = 'webhook:200000';
  end if;

  -- allowed_mentions (null = Discord's default for webhooks here: users yes, @everyone and roles no).
  parse := case when p_mentions is null then '["users"]'::jsonb
                when jsonb_typeof(p_mentions -> 'parse') = 'array' then p_mentions -> 'parse' else '[]'::jsonb end;
  allow_users := case when jsonb_typeof(p_mentions -> 'users') = 'array' then p_mentions -> 'users' else '[]'::jsonb end;
  allow_roles := case when jsonb_typeof(p_mentions -> 'roles') = 'array' then p_mentions -> 'roles' else '[]'::jsonb end;
  if body ~* '@(everyone|here)'
     and not (parse ? 'everyone' and public.webhook_user_perm(w.created_by, c.id, 'mention_everyone')) then
    body := regexp_replace(body, '@(everyone|here)', '@' || chr(8203) || '\1', 'gi');
  end if;
  if strpos(body, '<@&') > 0 and not (parse ? 'roles') then
    for r in select distinct x[1] as rid from regexp_matches(body, '<@&([0-9a-f-]{36})>', 'g') x loop
      continue when allow_roles ? r.rid;
      body := replace(body, '<@&' || r.rid || '>', '@' || chr(8203) || coalesce(
        (select translate(ro.name, '<>', '') from public.roles ro where ro.id::text = r.rid and ro.server_id = c.server_id), 'deleted-role'));
    end loop;
  end if;
  if strpos(body, '<@') > 0 and not (parse ? 'users') then
    for r in select distinct x[1] as uid from regexp_matches(body, '<@([0-9a-f-]{36})>', 'g') x loop
      continue when allow_users ? r.uid;
      body := replace(body, '<@' || r.uid || '>', '@' || chr(8203) || coalesce(
        (select p.username from public.profiles p where p.id::text = r.uid), 'unknown-user'));
    end loop;
  end if;

  perform set_config('yapper.bot', '1', true);
  perform set_config('yapper.webhook', '1', true);
  insert into public.messages (channel_id, author_id, content, embeds, components, webhook)
  values (c.id, author, body, p_embeds, p_components, jsonb_build_object('id', w.id, 'name', n, 'avatar_url', p_avatar_url,
          'avatar_path', case when p_avatar_url is null then w.avatar_path end))
  returning * into m;
  perform set_config('yapper.webhook', '', true);
  perform set_config('yapper.bot', '', true);
  update public.webhooks set last_used_at = now(), posts = posts + 1 where id = w.id;
  return m;
end $$;
revoke all on function public.webhook_post(public.webhooks, text, text, text, jsonb, jsonb, jsonb) from public, anon, authenticated, service_role;

/** The token check every URL post starts with. Raises with the 155 hints. */
create or replace function public.webhook_by_token(wid uuid, tok text) returns public.webhooks
language plpgsql stable security definer set search_path = public as $$
declare w public.webhooks;
begin
  if tok is null or tok !~ '^[0-9a-f]{64}$' then raise exception 'Invalid Webhook Token' using hint = 'webhook:50027'; end if;
  select * into w from public.webhooks where id = wid;
  if w.id is null then raise exception 'Unknown Webhook' using hint = 'webhook:10015'; end if;
  if w.token_hash <> encode(sha256(convert_to(tok, 'UTF8')), 'hex') then
    raise exception 'Invalid Webhook Token' using hint = 'webhook:50027';
  end if;
  return w;
end $$;
revoke all on function public.webhook_by_token(uuid, text) from public, anon, authenticated, service_role;

/** 155's webhook_send, same signature and behaviour (no buttons). */
create or replace function public.webhook_send(wid uuid, tok text, body text, p_username text default null,
  p_avatar_url text default null, p_embeds jsonb default null, p_mentions jsonb default null)
returns public.messages language plpgsql security definer set search_path = public as $$
begin
  return public.webhook_post(public.webhook_by_token(wid, tok), body, p_username, p_avatar_url, p_embeds, p_mentions, null);
end $$;

/** webhook_send plus link buttons (flag embed_builder). The API calls it only when the body has components. */
create or replace function public.webhook_send_v2(wid uuid, tok text, body text, p_username text default null,
  p_avatar_url text default null, p_embeds jsonb default null, p_mentions jsonb default null, p_components jsonb default null)
returns public.messages language plpgsql security definer set search_path = public as $$
begin
  return public.webhook_post(public.webhook_by_token(wid, tok), body, p_username, p_avatar_url, p_embeds, p_mentions, p_components);
end $$;

/**
 * Can p_uid make a post as webhook wid right now? The webhook, or raises (hint webhook:10015 / 50001): flag, Manage
 * Webhooks in its channel (webhook_user_blocked), and a lock stops anyone without Manage Messages (the URL path checks
 * the creator instead, but here the poster is p_uid, so an admin's webhook doesn't get them round a lock).
 */
create or replace function public.webhook_member_guard(p_uid uuid, wid uuid) returns public.webhooks
language plpgsql security definer set search_path = public as $$
declare w public.webhooks;
begin
  select * into w from public.webhooks where id = wid;
  if w.id is null then raise exception 'That webhook is gone' using hint = 'webhook:10015'; end if;
  if not (public.feature_on('embed_builder', w.server_id)
          or exists (select 1 from public.feature_flags f where f.key = 'embed_builder' and f.mode = 'test' and p_uid = any(f.users))) then
    raise exception 'Making posts isn''t on in this server yet' using hint = 'webhook:50001';
  end if;
  if public.webhook_user_blocked(p_uid, w.channel_id) is not null then
    raise exception 'You need Manage Webhooks in this channel for that' using hint = 'webhook:50001';
  end if;
  if public.server_locked(w.server_id) and not public.webhook_user_perm(p_uid, w.channel_id, 'manage_messages') then
    raise exception 'This server is locked by its mods right now' using hint = 'webhook:50001';
  end if;
  return w;
end $$;
revoke all on function public.webhook_member_guard(uuid, uuid) from public, anon, authenticated, service_role;

/**
 * The rate limit for Make a post, as its own call before webhook_post_member (like webhook_take for URLs), so it is
 * committed even when the post then fails (filters, bad body). {"ok": true} or {"code": 429, "retry_after": seconds}.
 */
create or replace function public.webhook_take_member(p_uid uuid, wid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.webhooks; wait numeric;
begin
  w := public.webhook_member_guard(p_uid, wid);
  wait := public.webhook_hit('w:' || w.id::text, 2, 5);
  if wait = 0 then wait := public.webhook_hit('c:' || w.channel_id::text, 60, 30); end if;
  if wait > 0 then return jsonb_build_object('code', 429, 'retry_after', wait); end if;
  return jsonb_build_object('ok', true);
end $$;

/**
 * Make a post (the embed builder): p_uid posts as webhook wid without its token. The API route has checked who p_uid
 * is, taken the rate limit (webhook_take_member) and cleaned the embeds and buttons.
 * Default mentions (users ping, @everyone and roles don't), the webhook's own name and picture.
 */
create or replace function public.webhook_post_member(p_uid uuid, wid uuid, body text, p_embeds jsonb default null, p_components jsonb default null)
returns public.messages language plpgsql security definer set search_path = public as $$
begin
  return public.webhook_post(public.webhook_member_guard(p_uid, wid), body, null, null, p_embeds, null, p_components);
end $$;

revoke all on function public.webhook_send(uuid, text, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.webhook_send_v2(uuid, text, text, text, text, jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.webhook_post_member(uuid, uuid, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.webhook_take_member(uuid, uuid) from public, anon, authenticated;
grant execute on function public.webhook_send(uuid, text, text, text, text, jsonb, jsonb) to service_role;
grant execute on function public.webhook_send_v2(uuid, text, text, text, text, jsonb, jsonb, jsonb) to service_role;
grant execute on function public.webhook_post_member(uuid, uuid, text, jsonb, jsonb) to service_role;
grant execute on function public.webhook_take_member(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
