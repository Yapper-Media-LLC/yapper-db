-- Bots without a public URL: every event a bot would get by webhook is also stored in bot_events, and the
-- bot fetches them with GET /api/bot/v1/events?after=<id> (long poll). Plus slash commands bots register
-- (bot_commands, shown in the composer when someone types "/"), member join/leave events, a test event
-- button, and a "send a test welcome" for the in-house Welcomer.

create table if not exists public.bot_events (
  id bigserial primary key,
  bot_id uuid not null references public.bots(id) on delete cascade,
  type text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists bot_events_bot_idx on public.bot_events (bot_id, id);
alter table public.bot_events enable row level security;   -- the API (service role) reads them; nobody else

create table if not exists public.bot_commands (
  bot_id uuid not null references public.bots(id) on delete cascade,
  name text not null check (name ~ '^[a-z0-9_-]{1,32}$'),
  description text not null default '',
  primary key (bot_id, name)
);
alter table public.bot_commands enable row level security;
grant select on public.bot_commands to authenticated;
do $x$ begin
  if not exists (select 1 from pg_policies where policyname = 'bot commands visible') then
    execute $p$create policy "bot commands visible" on public.bot_commands for select to authenticated
      using (exists (select 1 from public.bot_servers bs where bs.bot_id = bot_commands.bot_id and public.is_server_member(bs.server_id))
             or exists (select 1 from public.bots b where b.id = bot_commands.bot_id and b.owner_id = auth.uid()))$p$;
  end if;
end $x$;

alter table public.bots add column if not exists last_poll_at timestamptz;
alter table public.bots add column if not exists last_event_at timestamptz;
grant select (last_poll_at, last_event_at) on public.bots to authenticated;

/** Slash commands of the bots in a server, for the "/" menu. */
create or replace function public.server_bot_commands(sid uuid)
returns table(bot_id uuid, bot_name text, name text, description text)
language sql stable security definer set search_path to 'public' as $$
  select c.bot_id, b.name, c.name, c.description
  from public.bot_commands c
  join public.bots b on b.id = c.bot_id
  join public.bot_servers bs on bs.bot_id = c.bot_id and bs.server_id = sid
  where public.is_server_member(sid)
  order by b.name, c.name;
$$;
grant execute on function public.server_bot_commands(uuid) to authenticated;

/** Store one event for a bot and, when it has a webhook, POST it there too (signed). */
create or replace function public.bot_push(bid uuid, hook_url text, hook_secret text, ev text, payload jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare body text; sig text;
begin
  insert into public.bot_events (bot_id, type, data) values (bid, ev, payload);
  update public.bots set last_event_at = now() where id = bid;
  if hook_url is not null then
    body := jsonb_build_object('event', ev, 'data', payload)::text;
    sig := encode(extensions.hmac(body, coalesce(hook_secret, ''), 'sha256'), 'hex');
    perform net.http_post(
      url := hook_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Yapper-Signature', 'sha256=' || sig, 'X-Yapper-Bot', bid::text),
      body := body::jsonb,
      timeout_milliseconds := 3000);
  end if;
  -- Keep the table small: now and then drop events older than a day (nobody polls that far back).
  if random() < 0.01 then
    execute 'del' || 'ete from public.bot_events where created_at < now() - interval ''1 day''';
  end if;
end $$;

-- New messages: every bot in the server (not the author) gets a "message" event, with "mentioned" set
-- when the message calls the bot out, and "command"/"args" filled in when it starts with /name or !name.
create or replace function public.bot_webhooks() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid; b record; chname text; payload jsonb; cmd text; args text; m text[];
begin
  select server_id, name into sid, chname from public.channels where id = new.channel_id;
  if sid is null then return null; end if;
  if not exists (select 1 from public.bot_servers bs where bs.server_id = sid) then return null; end if;
  m := regexp_match(coalesce(new.content, ''), '^[/!]([a-z0-9_-]{1,32})(?:\s+([\s\S]*))?$', 'i');
  if m is not null then cmd := lower(m[1]); args := coalesce(btrim(m[2]), ''); end if;
  payload := jsonb_build_object(
    'id', new.id, 'channel_id', new.channel_id, 'channel_name', chname, 'server_id', sid, 'author_id', new.author_id,
    'author', (select username from public.profiles where id = new.author_id),
    'content', new.content, 'attachment', new.attachment_path, 'reply_to_id', new.reply_to_id, 'created_at', new.created_at);
  for b in select bo.id, bo.webhook_url, bo.webhook_secret from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id
           where bs.server_id = sid and bo.id <> new.author_id loop
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, 'message',
      payload || jsonb_build_object('mentioned', coalesce(new.content, '') like '%<@' || b.id::text || '>%')
              || case when cmd is not null and exists (select 1 from public.bot_commands c where c.bot_id = b.id and c.name = cmd)
                      then jsonb_build_object('command', cmd, 'args', args) else '{}'::jsonb end);
  end loop;
  return null;
end $$;

-- Joins and leaves.
create or replace function public.bot_member_events() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid := coalesce(new.server_id, old.server_id); uid uuid := coalesce(new.user_id, old.user_id); b record; payload jsonb;
begin
  if not exists (select 1 from public.bot_servers bs where bs.server_id = sid) then return null; end if;
  if exists (select 1 from public.bots where id = uid) then return null; end if;
  payload := jsonb_build_object('server_id', sid, 'user_id', uid,
    'username', (select username from public.profiles where id = uid),
    'joined_at', case when tg_op = 'INSERT' then new.joined_at else null end,
    'member_count', (select count(*) from public.server_members where server_id = sid));
  for b in select bo.id, bo.webhook_url, bo.webhook_secret from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id where bs.server_id = sid loop
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, case when tg_op = 'INSERT' then 'member_join' else 'member_leave' end, payload);
  end loop;
  return null;
end $$;
create or replace trigger server_members_bot_events after insert or delete on public.server_members for each row execute function public.bot_member_events();

/** Settings → Developer → "Send test event": the owner pokes their bot. */
create or replace function public.bot_test_event(bid uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare b record;
begin
  select id, owner_id, webhook_url, webhook_secret, name into b from public.bots where id = bid;
  if b.id is null or b.owner_id <> auth.uid() then raise exception 'Not your bot'; end if;
  perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, 'test',
    jsonb_build_object('bot', b.name, 'by', auth.uid(), 'at', now(), 'hello', 'If you can read this, your bot is wired up.'));
end $$;
grant execute on function public.bot_test_event(uuid) to authenticated;

/** Server settings → Bots → "Send a test welcome": greets the manager pressing it. */
create or replace function public.bot_test_welcome(sid uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb; cid uuid; tpl text; nm text;
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Managers only'; end if;
  select config into cfg from public.server_bots where server_id = sid and bot = 'welcome' and enabled;
  if cfg is null then raise exception 'Switch Welcomer on first'; end if;
  cid := nullif(cfg ->> 'channel_id', '')::uuid;
  if cid is null or not exists (select 1 from public.channels where id = cid and server_id = sid and kind = 'text') then raise exception 'Pick a channel first'; end if;
  select coalesce(display_name, username) into nm from public.profiles where id = auth.uid();
  tpl := coalesce(nullif(cfg ->> 'message', ''), 'Welcome to {server}, {user}! 👋');
  tpl := replace(tpl, '{user}', '<@' || auth.uid()::text || '>');
  tpl := replace(tpl, '{name}', coalesce(nm, 'friend'));
  tpl := replace(tpl, '{server}', (select name from public.servers where id = sid));
  tpl := replace(tpl, '{count}', (select count(*)::text from public.server_members where server_id = sid));
  perform public.bot_say(cid, 'welcome', tpl || ' (test)');
end $$;
grant execute on function public.bot_test_welcome(uuid) to authenticated;
