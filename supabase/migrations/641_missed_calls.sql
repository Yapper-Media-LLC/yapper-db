-- 641: missed calls show up in the DM as a message (flag missed_calls, Antic Oct 28: "missed calls like in discord
-- show up in chat as message"). When a DM call ends before anyone picked up, the chat gets one system-style line
-- "Missed call from NAME" with a Call back button; an answered call gets "Call, 12 min" when it ends.
--
-- Who knows a call was missed: the database. Ringing is only the client's 30 s timer (lib/calls.ts), the realtime
-- server knows nothing about calls, and a call ends by end_call (caller gives up, or the last one leaves), by the
-- tab-close keepalive, or by the LiveKit room_finished webhook (service role). All of them set calls.ended_at, so
-- an AFTER UPDATE trigger on calls is the one place that sees every end. "Answered" is new: calls.answered_at, set
-- when someone other than the caller joins (the LiveKit participant_joined webhook with the service role, and the
-- ticket route as the joiner through call_joined; one covers the other's gap). start_call clears it when the same
-- row rings again.
--
-- Nothing a client can fake: the note is written by the trigger from the calls row, never from client input.
-- The new messages.system column marks these rows; a guard trigger nulls it on any insert that isn't ours
-- (yapper.system = '1', the same pattern as messages.webhook in 155) and keeps it from changing later. Old tabs
-- without the column show the fallback text ("Missed call", "Call, 12 min") as a normal message from the caller.
--
-- DDL (two columns, triggers, functions): both PostgRESTs reload their schema cache, apply in quiet hours.
-- No backfill, no data rewrite: add column with no default is metadata only on messages. Re-runnable.

alter table public.calls add column if not exists answered_at timestamptz;
alter table public.messages add column if not exists system jsonb;

-- ---------- Only the database writes messages.system ----------
create or replace function public.message_system_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('yapper.system', true), '') <> '1' then new.system := null; end if;
  else
    new.system := old.system;
  end if;
  return new;
end $$;
revoke all on function public.message_system_guard() from public, anon, authenticated;
create or replace trigger messages_system_insert before insert on public.messages
  for each row when (new.system is not null) execute function public.message_system_guard();
create or replace trigger messages_system_update before update of system on public.messages
  for each row when (new.system is distinct from old.system) execute function public.message_system_guard();

-- ---------- start_call: a call that rings again starts unanswered ----------
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
  on conflict (channel_id) do update set started_by = excluded.started_by, started_at = now(), ended_at = null, answered_at = null
  returning * into row;
  return row;
end;
$$;
grant execute on function public.start_call(uuid) to authenticated;

-- ---------- Someone picked up ----------
-- Called by /api/livekit-token as the person joining (next to voice_ticket, so no extra wait). Only a member who
-- isn't the caller can mark the call answered, and it only ever moves from null to now(): the worst a modified
-- client can do is mark a call it was invited to as answered without joining, which only hides its own missed-call
-- line. The LiveKit webhook sets the same column with the service role when the person really connects.
create or replace function public.call_joined(cid uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.calls set answered_at = now()
  where channel_id = cid and ended_at is null and answered_at is null
    and started_by <> auth.uid() and public.is_channel_member(cid);
$$;
revoke all on function public.call_joined(uuid) from public, anon;
grant execute on function public.call_joined(uuid) to authenticated;

-- ---------- The note in the chat when a DM call ends ----------
-- Missed (nobody answered): "Missed call" from the caller, system {kind: 'call_missed'}. At most one per caller per
-- chat a minute, so ringing again and again doesn't fill the chat. Answered: "Call, 12 min" from the caller, system
-- {kind: 'call', secs}. DMs only (a group call has no one person to call back). Flag missed_calls: on for everyone,
-- or in test when either person in the DM is in the test group (Antic can test both directions).
create or replace function public.call_note()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare secs int; body text; sys jsonb;
begin
  if not exists (select 1 from public.channels c where c.id = new.channel_id and c.kind = 'dm') then return null; end if;
  if not exists (
    select 1 from public.feature_flags f
    where f.key = 'missed_calls'
      and (f.mode = 'everyone' or (f.mode = 'test' and exists (
        select 1 from public.channel_members cm
        where cm.channel_id = new.channel_id
          and (cm.user_id = any(f.users)
               or exists (select 1 from public.server_members sm where sm.user_id = cm.user_id and sm.server_id = any(f.servers))))))
  ) then return null; end if;

  if new.answered_at is null then
    if exists (
      select 1 from public.messages m
      where m.channel_id = new.channel_id and m.author_id = new.started_by
        and m.created_at > now() - interval '60 seconds' and m.system ->> 'kind' = 'call_missed'
    ) then return null; end if;
    body := 'Missed call';
    sys := jsonb_build_object('kind', 'call_missed');
  else
    secs := greatest(0, extract(epoch from (new.ended_at - new.answered_at))::int);
    body := 'Call, ' || case when secs < 60 then secs || ' sec' else (secs / 60) || ' min' end;
    sys := jsonb_build_object('kind', 'call', 'secs', secs);
  end if;

  -- Written as the app's own line, not as the caller typing: the guards that look at who is posting (perms, raid
  -- rules, verification) step aside like they do for bots, and the system guard above lets the mark through.
  -- In its own sub-transaction: a guard that still refuses (a brand-new account's 3-second rule, a ban) must never
  -- stop the call from ending, it only costs the line.
  begin
    perform set_config('yapper.bot', '1', true);
    perform set_config('yapper.system', '1', true);
    insert into public.messages (channel_id, author_id, content, system) values (new.channel_id, new.started_by, body, sys);
    perform set_config('yapper.bot', '', true);
    perform set_config('yapper.system', '', true);
  exception when others then
    perform set_config('yapper.bot', '', true);
    perform set_config('yapper.system', '', true);
  end;
  return null;
end;
$$;
revoke all on function public.call_note() from public, anon, authenticated;
create or replace trigger calls_note after update of ended_at on public.calls
  for each row when (old.ended_at is null and new.ended_at is not null) execute function public.call_note();

-- ---------- Flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('missed_calls', 'Missed calls in chat', 'A DM call nobody picked up shows up in the chat as "Missed call from NAME" with a Call back button, and an answered call leaves a "Call, 12 min" line.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
