-- 229: jump to any message, however old (flag jump_to_message, test).
-- Two read-only windows on a channel's history, both built on channel_messages so access checks, profile columns
-- and reactions stay exactly the same as the normal "load older" pages:
--   channel_messages_around(cid, mid): the target message with ~24 older and up to 25 newer around it.
--   channel_messages_newer(cid, after): the next 50 messages after a timestamp ("load newer" while reading old ones).
-- Both add "at_end": true when nothing newer than the returned window exists (the window reaches the present).
-- Both use messages_channel_created_idx (channel_id, created_at desc). Re-runnable.

create or replace function public.channel_messages_around(cid uuid, mid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t timestamptz;
  newer timestamptz;
  bound timestamptz;
  at_end boolean;
begin
  if cid is null or mid is null or not public.can_access_channel(cid) or not public.channel_history_ok(cid) then
    return jsonb_build_object('messages', '[]'::jsonb, 'profiles', '[]'::jsonb, 'reactions', '[]'::jsonb, 'at_end', true, 'found', false);
  end if;
  select m.created_at into t from public.messages m where m.id = mid and m.channel_id = cid;
  if t is null then
    return jsonb_build_object('messages', '[]'::jsonb, 'profiles', '[]'::jsonb, 'reactions', '[]'::jsonb, 'at_end', true, 'found', false);
  end if;
  -- The 25th message newer than the target: the window ends right after it.
  select m.created_at into newer from public.messages m
   where m.channel_id = cid and m.created_at > t
   order by m.created_at asc offset 24 limit 1;
  if newer is null then
    bound := 'infinity';
    at_end := true;
  else
    bound := newer + interval '1 microsecond';
    at_end := not exists (select 1 from public.messages m where m.channel_id = cid and m.created_at >= bound);
  end if;
  return public.channel_messages(cid, bound, 50) || jsonb_build_object('at_end', at_end, 'found', true);
end;
$$;

create or replace function public.channel_messages_newer(cid uuid, after timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  newer timestamptz;
  n int;
  bound timestamptz;
  at_end boolean;
begin
  if cid is null or not public.can_access_channel(cid) or not public.channel_history_ok(cid) then
    return jsonb_build_object('messages', '[]'::jsonb, 'profiles', '[]'::jsonb, 'reactions', '[]'::jsonb, 'at_end', true);
  end if;
  if after is null then
    return public.channel_messages(cid, null, 50) || jsonb_build_object('at_end', true);
  end if;
  -- The 50th message newer than `after`: the page ends right after it.
  select m.created_at into newer from public.messages m
   where m.channel_id = cid and m.created_at > after
   order by m.created_at asc offset 49 limit 1;
  if newer is null then
    bound := 'infinity';
    at_end := true;
  else
    bound := newer + interval '1 microsecond';
    at_end := not exists (select 1 from public.messages m where m.channel_id = cid and m.created_at >= bound);
  end if;
  -- Exactly the rows between `after` and the bound (more than 50 when several share the 50th one's timestamp;
  -- a fixed 50 would push the oldest of them out of the page), at most 100.
  select count(*) into n from public.messages m where m.channel_id = cid and m.created_at > after and m.created_at < bound;
  return public.channel_messages(cid, bound, least(greatest(n, 1), 100)) || jsonb_build_object('at_end', at_end);
end;
$$;

revoke all on function public.channel_messages_around(uuid, uuid) from public, anon;
revoke all on function public.channel_messages_newer(uuid, timestamptz) from public, anon;
grant execute on function public.channel_messages_around(uuid, uuid) to authenticated;
grant execute on function public.channel_messages_newer(uuid, timestamptz) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('jump_to_message', 'Jump to any message', 'Search results, pins, replies, mentions and notifications take you to the message, however old', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
