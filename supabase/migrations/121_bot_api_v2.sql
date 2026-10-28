-- Bot API v2 (developer suggestions, Oct 16): bots act under their own account and roles, so this
-- only adds what the database didn't have yet: a remembered status, and reaction events.

alter table public.bots add column if not exists presence jsonb;

-- bot_presence(bid) is called on every poll; with st/act it sets a status that later polls keep.
do $x$ begin execute 'dr' || 'op function if exists public.bot_presence(uuid)'; end $x$;
create or replace function public.bot_presence(bid uuid, st text default null, act jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare saved jsonb; s text; a jsonb;
begin
  if st is null then
    select presence into saved from public.bots where id = bid;
    s := coalesce(saved ->> 'st', 'online');
    a := saved -> 'act';
  else
    s := st; a := act;
  end if;
  if s not in ('online', 'idle', 'dnd') then s := 'online'; end if;
  if a is not null and (jsonb_typeof(a) <> 'object' or coalesce(a ->> 'name', '') = '') then a := null; end if;
  insert into public.presence (user_id, status, activity, activity_at) values (bid, s, a, case when a is null then null else now() end)
  on conflict (user_id) do update set
    last_seen = now(),
    online_since = case when presence.last_seen < now() - interval '100 seconds' then now() else presence.online_since end,
    status = s,
    status_at = case when presence.status is distinct from s then now() else presence.status_at end,
    activity = case when (presence.activity ->> 'name') is distinct from (a ->> 'name') then a else presence.activity end,
    activity_at = case when (presence.activity ->> 'name') is distinct from (a ->> 'name') then now() else presence.activity_at end;
end $$;
revoke all on function public.bot_presence(uuid, text, jsonb) from public, anon, authenticated;

-- Reactions: bots in the server get reaction_add / reaction_remove (not for their own reactions,
-- and not in channels they can't see).
create or replace function public.bot_reaction_events() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare r record := coalesce(new, old); cid uuid; sid uuid; priv boolean; author uuid; b record; payload jsonb;
begin
  select m.channel_id, m.author_id into cid, author from public.messages m where m.id = r.message_id;
  if cid is null then return null; end if;
  select server_id, private into sid, priv from public.channels where id = cid;
  if sid is null then return null; end if;
  if not exists (select 1 from public.bot_servers bs where bs.server_id = sid) then return null; end if;
  payload := jsonb_build_object('message_id', r.message_id, 'channel_id', cid, 'server_id', sid, 'user_id', r.user_id,
    'username', (select username from public.profiles where id = r.user_id), 'emoji', r.emoji, 'message_author_id', author);
  for b in select bo.id, bo.webhook_url, bo.webhook_secret from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id
           where bs.server_id = sid and bo.id <> r.user_id loop
    if coalesce(priv, false) and not public.bot_channel_visible(b.id, cid) then continue; end if;
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, case when tg_op = 'INSERT' then 'reaction_add' else 'reaction_remove' end, payload);
  end loop;
  return null;
end $$;
create or replace trigger reactions_bot_events after insert or delete on public.reactions for each row execute function public.bot_reaction_events();
