-- 646: the call line also records how long the call rang (Antic after testing 641 on Oct 28: "make it more clear who
-- called who and what, like the details"). call_note (641) is the same function with one more key in
-- messages.system: rang = seconds from the ring start to the end (missed) or to the pickup (answered). The chat
-- shows "You called Test, no answer after 30 sec" / "Antic called you, no answer after 30 sec"; the rest of the
-- wording is client only (components/CallNote.tsx). Older lines have no rang and show without it.
-- One function replaced (DDL: PostgREST schema reload, apply in quiet hours). Re-runnable.

create or replace function public.call_note()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare secs int; rang int; body text; sys jsonb;
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
    rang := greatest(0, extract(epoch from (new.ended_at - new.started_at))::int);
    body := 'Missed call';
    sys := jsonb_build_object('kind', 'call_missed', 'rang', rang);
  else
    secs := greatest(0, extract(epoch from (new.ended_at - new.answered_at))::int);
    rang := greatest(0, extract(epoch from (new.answered_at - new.started_at))::int);
    body := 'Call, ' || case when secs < 60 then secs || ' sec' else (secs / 60) || ' min' end;
    sys := jsonb_build_object('kind', 'call', 'secs', secs, 'rang', rang);
  end if;

  -- Written as the app's own line, not as the caller typing: the guards that look at who is posting (perms, raid
  -- rules, verification) step aside like they do for bots, and the system guard (641) lets the mark through.
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
