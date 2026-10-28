-- Calls in DMs and group chats. The call itself runs on LiveKit (room = channel id, like voice
-- channels); this table only says "there's a call going on in this chat" and rings the others.

create table if not exists public.calls (
  channel_id uuid primary key references public.channels(id) on delete cascade,
  started_by uuid not null references public.profiles(id) on delete cascade,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);
alter table public.calls enable row level security;
create policy "members see calls" on public.calls for select to authenticated
  using (public.is_channel_member(channel_id));

-- Start (or re-open) a call in a DM or group you're in. Returns the row.
create or replace function public.start_call(cid uuid)
returns public.calls
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid(); c public.channels; row public.calls;
begin
  if me is null then raise exception 'Sign in first'; end if;
  select * into c from public.channels where id = cid;
  if c.id is null or c.server_id is not null or c.kind not in ('dm', 'group') then raise exception 'Calls only work in DMs and groups'; end if;
  if not public.is_channel_member(cid) then raise exception 'You’re not in this chat'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper'; end if;
  -- A DM with someone who blocked you (or you blocked) can't ring them.
  if c.kind = 'dm' and exists (
    select 1 from public.channel_members m join public.blocks b
      on (b.blocker = m.user_id and b.blocked = me) or (b.blocker = me and b.blocked = m.user_id)
    where m.channel_id = cid and m.user_id <> me
  ) then raise exception 'You can’t call this person'; end if;
  insert into public.calls (channel_id, started_by) values (cid, me)
  on conflict (channel_id) do update set started_by = excluded.started_by, started_at = now(), ended_at = null
  returning * into row;
  return row;
end;
$$;
grant execute on function public.start_call(uuid) to authenticated;

-- The last person leaving marks the call over (so nobody is shown "call in progress" forever).
create or replace function public.end_call(cid uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.calls set ended_at = now()
  where channel_id = cid and ended_at is null and public.is_channel_member(cid);
$$;
grant execute on function public.end_call(uuid) to authenticated;

-- Tell everyone in the chat (their own topic) when a call starts or ends.
create or replace function public.bc_call()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid;
begin
  for uid in select user_id from public.channel_members where channel_id = new.channel_id loop
    perform realtime.broadcast_changes('user:' || uid, 'call', tg_op, tg_table_name, tg_table_schema, new, old);
  end loop;
  return null;
end;
$$;
drop trigger if exists calls_bc on public.calls;
create trigger calls_bc after insert or update on public.calls for each row execute function public.bc_call();
