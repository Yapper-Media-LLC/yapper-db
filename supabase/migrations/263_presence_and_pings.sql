-- Presence fixes (bug reports 5fd85860, 3939fcf3, de09f4b8).
--
-- heartbeat: the account's chosen Idle now wins over "online" sent by another tab or device that hasn't caught
--   up yet (DND and Invisible already did), so you don't show Online to some people and Idle to others.
-- who_online: a "what changed since" poll that came more than 100 s after the previous one (tab asleep a
--   couple of minutes, throttled timers) skipped people who went offline in between, because the row filter
--   only looked 200 s back. They stayed green until a reload. The window now starts at since - ttl, which is
--   exactly what the "went offline" test below needs (and narrower than before for the normal 75 s poll).
-- Re-runnable: both are create or replace with the same signatures.

create or replace function public.heartbeat(st text, act jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); prev timestamptz; gap int; a jsonb; pf text;
begin
  if me is null then return; end if;
  -- The account's chosen status wins over whatever an older tab sends.
  select pref into pf from public.presence where user_id = me;
  if pf = 'invisible' and st is distinct from 'off' then st := 'invisible'; end if;
  if pf = 'dnd' and st in ('online', 'idle') then st := 'dnd'; end if;
  if pf = 'idle' and st = 'online' then st := 'idle'; end if;
  if st is null or st = 'invisible' or st = 'off' then
    update public.presence set last_seen = now() - interval '100 seconds' where user_id = me and last_seen > now() - interval '100 seconds';
    return;
  end if;
  if st not in ('online', 'idle', 'dnd') then st := 'online'; end if;
  if act is not null and jsonb_typeof(act) = 'object' and coalesce(act->>'name', '') <> '' then
    a := jsonb_build_object('name', left(act->>'name', 60), 'since', coalesce(act->>'since', now()::text));
  end if;
  select last_seen into prev from public.presence where user_id = me;
  if prev is not null and prev > now() - interval '100 seconds' then
    gap := least(60, greatest(0, extract(epoch from (now() - prev))::int));
    insert into public.online_time (user_id, day, secs) values (me, current_date, gap)
      on conflict (user_id, day) do update set secs = online_time.secs + excluded.secs;
  end if;
  insert into public.presence (user_id, status, activity, activity_at) values (me, st, a, case when a is null then null else now() end)
  on conflict (user_id) do update set
    last_seen = now(),
    online_since = case when presence.last_seen < now() - interval '100 seconds' then now() else presence.online_since end,
    status = excluded.status,
    status_at = case when presence.status is distinct from excluded.status then now() else presence.status_at end,
    activity = case when (presence.activity->>'name') is distinct from (excluded.activity->>'name') then excluded.activity else presence.activity end,
    activity_at = case when (presence.activity->>'name') is distinct from (excluded.activity->>'name') then now() else presence.activity_at end;
end $$;

create or replace function public.who_online(sid uuid, extra uuid[], since timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  ttl interval := interval '100 seconds';
  ids uuid[] := (coalesce(extra, '{}'::uuid[]))[1:500];
  -- Never later than now (a client clock can't push the window forward), never more than 10 minutes back.
  since_ timestamptz := case when since is null then null else greatest(least(since, now()), now() - interval '10 minutes') end;
  rows jsonb;
begin
  if me is null then return '{}'::jsonb; end if;
  if sid is not null and not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then sid := null; end if;
  select coalesce(jsonb_agg(jsonb_build_array(p.user_id, case when p.last_seen > now() - ttl then p.status else 'off' end, p.activity)), '[]'::jsonb)
    into rows
  from public.presence p
  where p.last_seen > coalesce(since_, now()) - ttl
    and (p.user_id = any(ids) or (sid is not null and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = p.user_id)))
    and (
      (since_ is null and p.last_seen > now() - ttl)
      or (since_ is not null and (p.online_since > since_ or p.status_at > since_ or p.activity_at > since_ or (p.last_seen <= now() - ttl and p.last_seen > since_ - ttl)))
    );
  return jsonb_build_object('now', now(), 'rows', rows);
end; $$;

-- Same grants as live (create or replace keeps them; restated for a fresh database).
revoke all on function public.heartbeat(text, jsonb) from public, anon;
revoke all on function public.who_online(uuid, uuid[], timestamptz) from public, anon;
grant execute on function public.heartbeat(text, jsonb) to authenticated;
grant execute on function public.who_online(uuid, uuid[], timestamptz) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- Pings (bug reports f2f1143e, 86e36450). Server messages only reach the channel being looked at; a ping elsewhere
-- also goes to the pinged person's own topic. Before, that was only a plain @mention, and without asking whether
-- they can see the channel:
--   * a role ping or a reply to you outside the open channel never made a sound (only a badge minutes later),
--   * an @mention in a private channel you can't see still dinged (and sent you the message) with nothing to click.
-- Now: @you, one of your roles (up to 50 people per message) or a reply to you, only if you're in the server and can
-- see the channel, never for a forwarded message (a quote doesn't ping again). Ids must look like real uuids, so a
-- typed "<@------------------------------------>" no longer makes the send fail on the cast.
-- Same signature and trigger as live (messages_broadcast); create or replace keeps the trigger.
create or replace function public.broadcast_message_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cid uuid; sid uuid; uid uuid; o public.messages;
  body text; targets uuid[]; open_ boolean; vis boolean; old_claims text; old_sub text;
  uuid_re constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if current_setting('yapper.bulk', true) = '1' then return null; end if;
  cid := coalesce(new.channel_id, old.channel_id);
  if tg_op = 'DELETE' then
    o := jsonb_populate_record(null::public.messages, jsonb_build_object('id', old.id, 'channel_id', old.channel_id, 'author_id', old.author_id));
  else
    o := old;
  end if;
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform public.bc('chan:' || cid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
    body := coalesce(new.content, '');
    if tg_op = 'INSERT' and not starts_with(body, chr(8618) || ' Forwarded' || chr(10))
       and (strpos(body, '<@') > 0 or new.reply_to_id is not null) then
      select array_agg(distinct t.x) into targets from (
        (select m[1]::uuid as x from regexp_matches(body, '<@(' || uuid_re || ')>', 'g') m limit 20)
        union all
        (select mr.user_id from public.member_roles mr
          where mr.server_id = sid
            and mr.role_id in (select m[1]::uuid from regexp_matches(body, '<@&(' || uuid_re || ')>', 'g') m limit 10)
          limit 50)
        union all
        (select pm.author_id from public.messages pm where new.reply_to_id is not null and pm.id = new.reply_to_id and pm.channel_id = cid)
      ) t
      where t.x is not null and t.x is distinct from new.author_id;
      if targets is not null then
        -- An open channel with no overrides: every member sees it, no need to ask per person.
        select not coalesce(ch.private, false)
               and not exists (select 1 from public.channel_overrides ov where ov.channel_id = ch.id or (ch.category_id is not null and ov.category_id = ch.category_id))
          into open_ from public.channels ch where ch.id = cid;
        old_claims := current_setting('request.jwt.claims', true);
        old_sub := current_setting('request.jwt.claim.sub', true);
        foreach uid in array targets loop
          if not exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = uid) then continue; end if;
          if not coalesce(open_, false) then
            -- can_access_channel answers for auth.uid(): ask it as that person, then put the sender back.
            perform set_config('request.jwt.claims', jsonb_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
            perform set_config('request.jwt.claim.sub', uid::text, true);
            vis := public.can_access_channel(cid);
            perform set_config('request.jwt.claims', coalesce(nullif(old_claims, ''), '{}'), true);
            perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
            if not coalesce(vis, false) then continue; end if;
          end if;
          perform public.bc('user:' || uid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
        end loop;
      end if;
    end if;
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      perform public.bc('user:' || uid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
    end loop;
  end if;
  return null;
end; $$;
