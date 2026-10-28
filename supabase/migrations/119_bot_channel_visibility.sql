-- Bots only see channels they could see as a member: public ones, plus private ones where the bot
-- (or a role it holds) was let in. Join/leave events carry the real member count (bots left out).

create or replace function public.bot_channel_visible(bid uuid, cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.channels c
    where c.id = cid
      and (
        (c.server_id is not null and exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = c.server_id)
          and (not c.private
               or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid)
               or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = bid where cr.channel_id = c.id)))
        or (c.server_id is null and exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid))
      )
  );
$$;

create or replace function public.bot_webhooks() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid; b record; chname text; priv boolean; payload jsonb; cmd text; args text; m text[];
begin
  select server_id, name, private into sid, chname, priv from public.channels where id = new.channel_id;
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
    if coalesce(priv, false) and not public.bot_channel_visible(b.id, new.channel_id) then continue; end if;
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, 'message',
      payload || jsonb_build_object('mentioned', coalesce(new.content, '') like '%<@' || b.id::text || '>%')
              || case when cmd is not null and exists (select 1 from public.bot_commands c where c.bot_id = b.id and c.name = cmd)
                      then jsonb_build_object('command', cmd, 'args', args) else '{}'::jsonb end);
  end loop;
  return null;
end $$;

create or replace function public.bot_member_events() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid := coalesce(new.server_id, old.server_id); uid uuid := coalesce(new.user_id, old.user_id); b record; payload jsonb;
begin
  if not exists (select 1 from public.bot_servers bs where bs.server_id = sid) then return null; end if;
  if public.is_bot_user(uid) then return null; end if;
  payload := jsonb_build_object('server_id', sid, 'user_id', uid,
    'username', (select username from public.profiles where id = uid),
    'joined_at', case when tg_op = 'INSERT' then new.joined_at else null end,
    'member_count', (select member_count from public.servers where id = sid));
  for b in select bo.id, bo.webhook_url, bo.webhook_secret from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id where bs.server_id = sid loop
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, case when tg_op = 'INSERT' then 'member_join' else 'member_leave' end, payload);
  end loop;
  return null;
end $$;

create or replace function public.bot_api_post(bid uuid, cid uuid, body text, reply uuid default null) returns public.messages
language plpgsql security definer set search_path = public as $$
declare m public.messages; recent int;
begin
  if not public.bot_channel_visible(bid, cid) then raise exception 'No such channel, or the bot cannot see it'; end if;
  select count(*) into recent from public.messages where author_id = bid and created_at > now() - interval '1 minute';
  if recent >= 30 then raise exception 'Slow down: 30 messages a minute per bot' using errcode = 'P0001'; end if;
  if body is null or btrim(body) = '' then raise exception 'Empty message'; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id) values (cid, bid, left(body, 2000), reply) returning * into m;
  perform set_config('yapper.bot', '', true);
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  return m;
end; $$;
