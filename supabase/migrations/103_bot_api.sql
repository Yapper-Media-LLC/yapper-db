-- Bots for everyone (flag bot_api): make a bot in Settings → Developer, get a token, add it to servers you
-- manage, and talk to Yapper over /api/bot/v1 (see /developers). New messages in those servers are POSTed
-- to the bot's webhook URL, signed with its secret.

create table if not exists public.bots (
  id uuid primary key references public.profiles(id) on delete cascade,  -- the bot's own account
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  description text not null default '',
  token_hash text,                 -- sha256 of the token; the token itself is shown once
  token_prefix text,
  webhook_url text,
  webhook_secret text,
  public boolean not null default false,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  posts bigint not null default 0
);
create index if not exists bots_owner on public.bots (owner_id);
alter table public.bots enable row level security;
-- Owners see their bots (never the hashes/secrets: those columns are not granted); everyone sees public bots' basics.
grant select (id, owner_id, name, description, public, created_at, last_used_at, posts, webhook_url) on public.bots to authenticated;
create policy "bots visible" on public.bots for select to authenticated using (owner_id = auth.uid() or public);

create table if not exists public.bot_servers (
  bot_id uuid not null references public.bots(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  added_by uuid,
  added_at timestamptz not null default now(),
  primary key (bot_id, server_id)
);
alter table public.bot_servers enable row level security;
grant select on public.bot_servers to authenticated;
create policy "bot servers visible" on public.bot_servers for select to authenticated
  using (public.is_server_member(server_id) or exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = auth.uid()));

/** Add a bot to a server you manage (yours, or a public one). The bot becomes a member. */
create or replace function public.bot_add_to_server(bid uuid, sid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.feature_on('bot_api', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can add bots'; end if;
  if not exists (select 1 from public.bots b where b.id = bid and (b.owner_id = auth.uid() or b.public)) then raise exception 'That bot isn''t available'; end if;
  if (select count(*) from public.bot_servers where server_id = sid) >= 25 then raise exception 'That server has enough bots already'; end if;
  insert into public.bot_servers (bot_id, server_id, added_by) values (bid, sid, auth.uid()) on conflict do nothing;
  perform set_config('yapper.bot', '1', true);
  insert into public.server_members (server_id, user_id) values (sid, bid) on conflict do nothing;
  perform set_config('yapper.bot', '', true);
end; $$;
grant execute on function public.bot_add_to_server(uuid, uuid) to authenticated;

create or replace function public.bot_remove_from_server(bid uuid, sid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.server_perm(sid, 'manage_server') or exists (select 1 from public.bots b where b.id = bid and b.owner_id = auth.uid())) then
    raise exception 'Only server managers (or the bot''s owner) can remove bots';
  end if;
  delete from public.bot_servers where bot_id = bid and server_id = sid;
  delete from public.server_members where server_id = sid and user_id = bid;
end; $$;
grant execute on function public.bot_remove_from_server(uuid, uuid) to authenticated;

/** The API (service role) posts as a bot through here: membership, rate limit, and the send guards skipped like in-house bots. */
create or replace function public.bot_api_post(bid uuid, cid uuid, body text, reply uuid default null) returns public.messages
language plpgsql security definer set search_path = public as $$
declare sid uuid; m public.messages; recent int;
begin
  select server_id into sid from public.channels where id = cid;
  if sid is null then
    if not exists (select 1 from public.channel_members where channel_id = cid and user_id = bid) then raise exception 'No such channel'; end if;
  elsif not exists (select 1 from public.bot_servers where bot_id = bid and server_id = sid) then
    raise exception 'The bot isn''t in that server';
  end if;
  select count(*) into recent from public.messages where author_id = bid and created_at > now() - interval '1 minute';
  if recent >= 30 then raise exception 'Slow down: 30 messages a minute per bot' using errcode = 'P0001'; end if;
  if body is null or btrim(body) = '' then raise exception 'Empty message'; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id) values (cid, bid, left(body, 2000), reply) returning * into m;
  perform set_config('yapper.bot', '', true);
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  return m;
end; $$;

-- Bots that were added to a server may post anywhere in it (the #bots-only rule is for unregistered bot-like accounts).
create or replace function public.bots_only_in_bots() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch record;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  if not exists (select 1 from public.profiles p where p.id = new.author_id and 'bot' = any(coalesce(p.badges, '{}'::text[]))) then return new; end if;
  if exists (select 1 from public.bot_accounts where user_id = new.author_id) then return new; end if;
  select c.name, c.server_id into ch from public.channels c where c.id = new.channel_id;
  if ch.server_id is not null and exists (select 1 from public.bot_servers where bot_id = new.author_id and server_id = ch.server_id) then return new; end if;
  if ch.server_id is not null and ch.name !~* 'bot' then
    raise exception 'Bots can only post in bot channels (like #bots).' using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- Outgoing webhooks: every new message in a server the bot is in (not its own) is POSTed to its webhook URL,
-- signed: X-Yapper-Signature: sha256=<hmac-sha256(secret, body)>.
create extension if not exists pgcrypto;
create or replace function public.bot_webhooks() returns trigger
language plpgsql security definer set search_path = public as $$
declare sid uuid; b record; body text; sig text; chname text;
begin
  select server_id, name into sid, chname from public.channels where id = new.channel_id;
  if sid is null then return null; end if;
  if not exists (select 1 from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id where bs.server_id = sid and bo.webhook_url is not null) then return null; end if;
  body := jsonb_build_object(
    'event', 'message',
    'data', jsonb_build_object(
      'id', new.id, 'channel_id', new.channel_id, 'channel_name', chname, 'server_id', sid, 'author_id', new.author_id,
      'author', (select username from public.profiles where id = new.author_id),
      'content', new.content, 'attachment', new.attachment_path, 'reply_to_id', new.reply_to_id, 'created_at', new.created_at))::text;
  for b in select bo.id, bo.webhook_url, bo.webhook_secret from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id
           where bs.server_id = sid and bo.webhook_url is not null and bo.id <> new.author_id loop
    sig := encode(hmac(body, coalesce(b.webhook_secret, ''), 'sha256'), 'hex');
    perform net.http_post(
      url := b.webhook_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Yapper-Signature', 'sha256=' || sig, 'X-Yapper-Bot', b.id::text),
      body := body::jsonb,
      timeout_milliseconds := 3000);
  end loop;
  return null;
end; $$;
create or replace trigger messages_bot_webhooks after insert on public.messages for each row execute function public.bot_webhooks();

insert into public.feature_flags (key, label, description, mode, users)
  values ('bot_api', 'Bot platform', 'Make your own bots (Settings → Developer), add them to servers, API at /api/bot/v1', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
  on conflict (key) do nothing;
