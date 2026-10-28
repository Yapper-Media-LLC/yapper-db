-- ============================================================
-- Yapper · Messages and reactions by broadcast (applied to production 2026-10-13)
-- postgres_changes re-checked RLS for every connected client on every change
-- (~280 ms per change with thousands online). Now a trigger broadcasts each
-- change to one topic per server (or per DM/group), and the right to listen is
-- checked once at subscribe time by the policy on realtime.messages.
-- ============================================================

-- Topics: 'server:<id>' for server channels; DMs/groups go to each member's 'user:<id>'.
create or replace function public.broadcast_message_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; sid uuid; uid uuid;
begin
  cid := coalesce(new.channel_id, old.channel_id);
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform realtime.broadcast_changes('server:' || sid, 'message', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      perform realtime.broadcast_changes('user:' || uid, 'message', tg_op, tg_table_name, tg_table_schema, new, old);
    end loop;
  end if;
  return null;
end;
$$;
create or replace function public.broadcast_reaction_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; sid uuid; uid uuid;
begin
  select channel_id into cid from public.messages where id = coalesce(new.message_id, old.message_id);
  if cid is null then return null; end if;
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform realtime.broadcast_changes('server:' || sid, 'reaction', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      perform realtime.broadcast_changes('user:' || uid, 'reaction', tg_op, tg_table_name, tg_table_schema, new, old);
    end loop;
  end if;
  return null;
end;
$$;
drop trigger if exists messages_broadcast on public.messages;
create trigger messages_broadcast after insert or update or delete on public.messages for each row execute function public.broadcast_message_change();
drop trigger if exists reactions_broadcast on public.reactions;
create trigger reactions_broadcast after insert or delete on public.reactions for each row execute function public.broadcast_reaction_change();

drop policy if exists "members listen to their topics" on realtime.messages;
create policy "members listen to their topics" on realtime.messages for select to authenticated using (
  (realtime.topic() like 'server:%' and exists (select 1 from public.server_members m where m.server_id = split_part(realtime.topic(), ':', 2)::uuid and m.user_id = auth.uid()))
  or (realtime.topic() like 'chan:%' and public.can_access_channel(split_part(realtime.topic(), ':', 2)::uuid))
);
drop policy if exists "own topic" on realtime.messages;
create policy "own topic" on realtime.messages for select to authenticated using (realtime.topic() = 'user:' || auth.uid()::text);

-- Member joins/leaves/nickname changes ride the server topic too.
create or replace function public.broadcast_member_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.broadcast_changes('server:' || coalesce(new.server_id, old.server_id), 'member', tg_op, tg_table_name, tg_table_schema, new, old);
  return null;
end;
$$;
drop trigger if exists server_members_broadcast on public.server_members;
create trigger server_members_broadcast after insert or update or delete on public.server_members for each row execute function public.broadcast_member_change();
