-- Applied live.
-- Bot buttons (flag bot_buttons, test only): bots put up to 5 rows of 5 buttons on their messages (messages.components).
--   The bot API checks every button first (lib/components.ts); the database only checks the overall shape.
--   message_defaults / message_edit_guard: only the bot API (yapper.bot = 1) can set or change components, like embeds.
--   Changing only the buttons does not mark a message edited.
-- press_button(mid, button): a click. Checks the clicker can see the channel, isn't timed out, that the button is
--   there and not disabled, rate-limits (5 per 10 s, 30 a minute per person), then sends the bot an `interaction`
--   event (bot_push: event queue + webhook) with an interaction id and a one-off token. Returns the interaction id.
--   Only the token's sha256 is stored (bot_interactions.token); the raw token is only in the event to the bot.
--   The rate-limit count runs under a per-user advisory lock, so parallel clicks can't slip past it.
-- bot_interaction_respond(...): service role only (the bot API). Within 15 minutes, up to 10 answers per click
--   (claimed with one atomic update, so parallel answers can't pass the cap), and only while the bot can still see the channel:
--   reply (new message in the channel), update (edit the clicked message), ephemeral (only the clicker sees it), ack.
--   Every answer is kept in bot_interaction_replies (the clicker can read their own rows) and pushed to the clicker's
--   realtime topic user:<id> as event `interaction`. Ephemeral replies live nowhere else.
-- bot_api_send / bot_api_edit take p_components (and set_components) now; the old overloads are removed.
-- bot_push: no longer callable by signed-in users (only the definer triggers and functions call it), so nobody can
--   push fake events (or fake clicks) to a bot.
-- Old interaction rows are cleaned up after a day.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bot_buttons', 'Bot buttons', 'Bots can put buttons on their messages; clicks go to the bot as interaction events.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

alter table public.messages add column if not exists components jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'messages_components_shape' and conrelid = 'public.messages'::regclass) then
    alter table public.messages add constraint messages_components_shape check (
      components is null or (jsonb_typeof(components) = 'array' and jsonb_array_length(components) between 1 and 5 and octet_length(components::text) <= 8000)
    ) not valid;
  end if;
end $$;

-- ---------- clicks ----------
create table if not exists public.bot_interactions (
  id uuid primary key default gen_random_uuid(),
  token text not null,  -- sha256 (hex) of the token handed to the bot
  bot_id uuid not null,
  message_id uuid not null,
  channel_id uuid not null,
  server_id uuid,
  user_id uuid not null,
  custom_id text not null,
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  replies int not null default 0
);
create index if not exists bot_interactions_user_time on public.bot_interactions (user_id, created_at desc);
create index if not exists bot_interactions_time on public.bot_interactions (created_at);
alter table public.bot_interactions enable row level security;
revoke all on public.bot_interactions from public, anon, authenticated;

create table if not exists public.bot_interaction_replies (
  id uuid primary key default gen_random_uuid(),
  interaction_id uuid not null,
  bot_id uuid not null,
  user_id uuid not null,
  channel_id uuid not null,
  message_id uuid not null,
  kind text not null check (kind in ('ack', 'reply', 'update', 'ephemeral')),
  content text check (content is null or char_length(content) <= 2000),
  embeds jsonb check (embeds is null or (jsonb_typeof(embeds) = 'array' and jsonb_array_length(embeds) between 1 and 5 and octet_length(embeds::text) <= 16000)),
  created_at timestamptz not null default now()
);
create index if not exists bot_interaction_replies_interaction on public.bot_interaction_replies (interaction_id);
create index if not exists bot_interaction_replies_time on public.bot_interaction_replies (created_at);
alter table public.bot_interaction_replies enable row level security;
revoke all on public.bot_interaction_replies from public, anon, authenticated;
grant select on public.bot_interaction_replies to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bot_interaction_replies' and policyname = 'own interaction replies') then
    create policy "own interaction replies" on public.bot_interaction_replies for select to authenticated using (user_id = (select auth.uid()));
  end if;
end $$;

-- ---------- only the bot API sets components ----------
do $$
declare src text; out text;
begin
  src := pg_get_functiondef('public.message_defaults()'::regprocedure);
  if position('new.components := null' in src) = 0 then
    out := replace(src, 'then new.embeds := null; end if;', 'then new.embeds := null; new.components := null; end if;');
    if out = src then raise exception '147: message_defaults patch did not apply'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.message_edit_guard()'::regprocedure);
  if position('new.components := old.components' in src) = 0 then
    out := replace(src, 'then new.embeds := old.embeds; end if;', 'then new.embeds := old.embeds; new.components := old.components; end if;');
    if out = src then raise exception '147: message_edit_guard patch did not apply'; end if;
    execute out;
  end if;
end $$;

-- ---------- sending and editing (bot API, service role) ----------
do $$ begin
  if exists (select 1 from pg_proc where oid = to_regprocedure('public.bot_api_send(uuid, uuid, text, uuid, jsonb)')) then
    execute 'dr' || 'op function public.bot_api_send(uuid, uuid, text, uuid, jsonb)';
  end if;
  if exists (select 1 from pg_proc where oid = to_regprocedure('public.bot_api_edit(uuid, uuid, text, jsonb, boolean)')) then
    execute 'dr' || 'op function public.bot_api_edit(uuid, uuid, text, jsonb, boolean)';
  end if;
end $$;

create or replace function public.bot_api_send(bid uuid, cid uuid, body text, reply uuid default null, p_embeds jsonb default null, p_components jsonb default null)
returns public.messages language plpgsql security definer set search_path = public as $$
declare m public.messages; recent int; sid uuid;
begin
  if not public.bot_channel_visible(bid, cid) then raise exception 'No such channel, or the bot cannot see it'; end if;
  -- Voice channel chat (145) needs its flag; kept here so re-running 147 after 145 doesn't drop it.
  if exists (select 1 from public.channels c where c.id = cid and c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id)) then
    raise exception 'Chat in voice channels isn''t on in this server';
  end if;
  -- Voice channel chat (145) needs its flag; kept here so re-running 147 after 145 doesn't drop it.
  if exists (select 1 from public.channels c where c.id = cid and c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id)) then
    raise exception 'Chat in voice channels isn''t on in this server';
  end if;
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
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  return m;
end $$;

create or replace function public.bot_api_edit(bid uuid, mid uuid, body text, p_embeds jsonb, set_embeds boolean, p_components jsonb default null, set_components boolean default false)
returns public.messages language plpgsql security definer set search_path = public as $$
declare m public.messages; sid uuid;
begin
  select * into m from public.messages where id = mid and author_id = bid;
  if m.id is null then raise exception 'Bots can only edit their own messages'; end if;
  select server_id into sid from public.channels where id = m.channel_id;
  if set_embeds and p_embeds is not null and not public.feature_on('bot_embeds', sid) then raise exception 'Embeds aren''t available in this server yet'; end if;
  if set_components and p_components is not null and not public.feature_on('bot_buttons', sid) then raise exception 'Buttons aren''t available in this server yet'; end if;
  if btrim(coalesce(case when body is null then m.content else body end, '')) = '' and (case when set_embeds then p_embeds else m.embeds end) is null then
    raise exception 'A message needs content or embeds';
  end if;
  perform set_config('yapper.bot', '1', true);
  update public.messages set content = case when body is null then content else left(body, 2000) end,
    embeds = case when set_embeds then p_embeds else embeds end,
    components = case when set_components then p_components else components end
  where id = mid returning * into m;
  perform set_config('yapper.bot', '', true);
  return m;
end $$;

revoke all on function public.bot_api_send(uuid, uuid, text, uuid, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.bot_api_edit(uuid, uuid, text, jsonb, boolean, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.bot_api_send(uuid, uuid, text, uuid, jsonb, jsonb) to service_role;
grant execute on function public.bot_api_edit(uuid, uuid, text, jsonb, boolean, jsonb, boolean) to service_role;

-- Only triggers and definer functions push events to bots.
revoke all on function public.bot_push(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.bot_push(uuid, text, text, text, jsonb) to service_role;

-- ---------- a click ----------
create or replace function public.press_button(mid uuid, button text)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); m record; sid uuid; b record; iid uuid; tok text; n int;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if button is null or char_length(button) > 100 then raise exception 'That button isn''t there anymore'; end if;
  select id, channel_id, author_id, components into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'No such message'; end if;
  select server_id into sid from public.channels where id = m.channel_id;
  if not public.feature_on('bot_buttons', sid) then raise exception 'Buttons aren''t on here yet'; end if;
  if m.components is null or jsonb_typeof(m.components) <> 'array' or not exists (
    select 1 from jsonb_array_elements(m.components) r
    cross join lateral jsonb_array_elements(case when jsonb_typeof(r -> 'components') = 'array' then r -> 'components' else '[]'::jsonb end) x
    where x ->> 'custom_id' = button and coalesce(x ->> 'style', '') <> 'link' and coalesce(x -> 'disabled', 'false'::jsonb) <> 'true'::jsonb
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
revoke all on function public.press_button(uuid, text) from public, anon;
grant execute on function public.press_button(uuid, text) to authenticated;

-- ---------- the bot answers ----------
create or replace function public.bot_interaction_respond(bid uuid, iid uuid, tok text, kind text, body text default null,
  p_embeds jsonb default null, p_components jsonb default null, set_embeds boolean default false, set_components boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.bot_interactions; r public.bot_interaction_replies; msg public.messages; h text; prev public.bot_interactions;
begin
  if tok is null or tok !~ '^[0-9a-f]{48}$' then raise exception 'No such interaction'; end if;
  h := encode(extensions.digest(tok, 'sha256'), 'hex');
  -- One atomic claim: right bot, right token, not expired, under 10 answers. (Raising later undoes it.)
  update public.bot_interactions set replies = replies + 1, answered_at = coalesce(answered_at, now())
   where id = iid and bot_id = bid and token = h and created_at > now() - interval '15 minutes' and replies < 10
  returning * into i;
  if i.id is null then
    select * into prev from public.bot_interactions where id = iid and bot_id = bid and token = h;
    if prev.id is null then raise exception 'No such interaction'; end if;
    if prev.created_at <= now() - interval '15 minutes' then raise exception 'That interaction expired: answer within 15 minutes'; end if;
    raise exception 'Slow down: up to 10 answers per interaction';
  end if;
  if not public.bot_channel_visible(bid, i.channel_id) then raise exception 'That bot can''t see this channel anymore'; end if;
  if kind = 'reply' then
    msg := public.bot_api_send(bid, i.channel_id, body, null, p_embeds, p_components);
  elsif kind = 'update' then
    msg := public.bot_api_edit(bid, i.message_id, body, p_embeds, set_embeds, p_components, set_components);
  elsif kind = 'ephemeral' then
    if btrim(coalesce(body, '')) = '' and p_embeds is null then raise exception 'An ephemeral reply needs content or embeds'; end if;
    if p_embeds is not null and not public.feature_on('bot_embeds', i.server_id) then raise exception 'Embeds aren''t available in this server yet'; end if;
  elsif kind is distinct from 'ack' then
    raise exception 'type must be reply, ephemeral, update or ack';
  end if;
  insert into public.bot_interaction_replies (interaction_id, bot_id, user_id, channel_id, message_id, kind, content, embeds)
  values (i.id, bid, i.user_id, i.channel_id, i.message_id, kind,
          case when kind = 'ephemeral' then left(coalesce(body, ''), 2000) end, case when kind = 'ephemeral' then p_embeds end)
  returning * into r;
  perform public.bc('user:' || i.user_id, 'interaction', 'INSERT', 'bot_interaction_replies', 'public', r, null);
  return jsonb_build_object('ok', true, 'type', kind, 'message', case when msg.id is null then null else to_jsonb(msg) end);
end $$;
revoke all on function public.bot_interaction_respond(uuid, uuid, text, text, text, jsonb, jsonb, boolean, boolean) from public, anon, authenticated;
grant execute on function public.bot_interaction_respond(uuid, uuid, text, text, text, jsonb, jsonb, boolean, boolean) to service_role;

notify pgrst, 'reload schema';
