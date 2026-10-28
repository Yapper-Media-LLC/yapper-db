-- 562: @here, like Discord. Typing @here in a server channel pings the members who are online right now (status
-- online: not idle, not dnd, not invisible, not offline) and can see the channel. Same permission as @everyone
-- (mention_everyone, channel override included); without it the @ gets a zero-width space, like @everyone does.
-- Flag mention_here (test: Antic + HQ test server). Re-runnable.
--
-- Who is online comes from public.presence (the 45 s client heartbeat, 100 s window: the same source as who_online,
-- the invite card and the homepage counter). It is read once, when the message is sent, and the ids are kept on the
-- message (messages.here_to), because @everyone is found by a regex at read time but "who was online" is only known
-- at send time. The author and bots are never in the list; invisible people are not (their heartbeat keeps them out
-- of the window and pref says so).
--
-- Patched in place below (live text, anchors checked): unread_counts_for / unread_counts_v1 count a message whose
-- here_to has me as a mention; broadcast_message_change puts here_to in the live-badge notice so the client can
-- count it without a poll (up to 200 ids; a bigger @here sends none and the badge waits for the next count). The mentions inbox (my_mentions) is not changed: its prefilter rides the partial index
-- messages_pingy_idx (<@ or @everyone) and a here_to test there would lose it. Push (push_on_message) skips
-- @everyone today and skips @here too.

set lock_timeout = '2s';

-- 1. Who an @here reached. Set by the trigger only (it resets whatever the client sent).
alter table public.messages add column if not exists here_to uuid[];

-- 2. Can this person see this channel? The per-person twin of can_access_channel's server branch (owner, admin,
-- Manage Server, the channel's roles, automatic roles; channel overrides when they are live for the server).
-- cp: overrides are live for this channel (the caller knows). A public channel without them: yes, no role work.
create or replace function public.here_can_view(uid uuid, cid uuid, cp boolean)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare sid uuid; cat uuid; priv boolean; base boolean;
begin
  select c.server_id, c.category_id, coalesce(c.private, false) into sid, cat, priv from public.channels c where c.id = cid;
  if sid is null or uid is null then return false; end if;
  if not coalesce(cp, false) and not priv then return true; end if;
  base := exists (select 1 from public.servers s where s.id = sid and s.owner_id = uid)
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = uid
                 and (coalesce((r.perms->>'administrator')::boolean, false)
                      or coalesce((r.perms->>'manage_server')::boolean, false)
                      or r.manage_server))
    or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = uid
               where cr.channel_id = cid)
    or exists (select 1 from public.channel_roles cr where cr.channel_id = cid and public.auto_role_applies(cr.role_id, uid));
  if cp then return public.channel_perm_of(uid, cid, 'view_channel', base); end if;
  return (not priv) or base;
end $$;
revoke all on function public.here_can_view(uuid, uuid, boolean) from public, anon, authenticated;

-- 3. The online members of the server who can see the channel: not the author, not bots, not banned. At most 1000.
create or replace function public.here_targets(cid uuid, sid uuid, author uuid, cp boolean)
returns uuid[] language plpgsql stable security definer set search_path = public as $$
declare ids uuid[]; priv boolean;
begin
  select coalesce(c.private, false) into priv from public.channels c where c.id = cid;
  select array_agg(u.user_id) into ids
  from (
    select m.user_id
    from public.server_members m
    join public.presence p on p.user_id = m.user_id
    where m.server_id = sid
      and m.user_id is distinct from author
      and p.last_seen > now() - interval '100 seconds'
      and p.status = 'online'
      and p.pref is distinct from 'invisible'
      and not exists (select 1 from public.bots d where d.id = m.user_id)
      and not exists (select 1 from public.bot_accounts b where b.user_id = m.user_id)
      and not public.is_site_banned(m.user_id)
      and ((not coalesce(cp, false) and not priv) or public.here_can_view(m.user_id, cid, cp))
    order by p.last_seen desc
    limit 1000
  ) u;
  return ids;
end $$;
revoke all on function public.here_targets(uuid, uuid, uuid, boolean) from public, anon, authenticated;

-- 4. Before insert, after the permission and raid guards (name order): the permission test, the zero-width space
-- when it fails, and the list of people reached when it passes. Bots and webhooks skip the test like the other
-- guards do (webhook_post already defused @here unless the webhook's maker may ping everyone).
create or replace function public.message_here_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; cp boolean; allowed boolean;
begin
  new.here_to := null;
  if new.content !~ '(^|[^A-Za-z0-9_@])@here\M' then return new; end if;
  select c.server_id,
         exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                 and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
         and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
    into sid, cp
  from public.channels c where c.id = new.channel_id;
  if sid is null then return new; end if;
  if not public.feature_on('mention_here', sid) then return new; end if;
  if current_setting('yapper.bot', true) = '1' or new.webhook is not null then
    allowed := true;
  else
    allowed := case when cp then public.channel_perm(new.channel_id, 'mention_everyone') else public.server_perm(sid, 'mention_everyone') end;
  end if;
  if not coalesce(allowed, false) then
    new.content := regexp_replace(new.content, '(^|[^A-Za-z0-9_@])@here\M', '\1@' || chr(8203) || 'here', 'g');
    return new;
  end if;
  -- A forwarded message is a quote: its @here pings nobody again.
  if starts_with(new.content, chr(8618) || ' Forwarded' || chr(10)) then return new; end if;
  new.here_to := public.here_targets(new.channel_id, sid, new.author_id, cp);
  return new;
end $$;
revoke all on function public.message_here_guard() from public, anon, authenticated;
create or replace trigger messages_zz_here_guard before insert on public.messages
  for each row execute function public.message_here_guard();

-- 4b. Nobody edits the list afterwards (the edit policy has no column list; same lock as webhook in 155).
create or replace function public.message_here_lock()
returns trigger language plpgsql set search_path = public as $$
begin new.here_to := old.here_to; return new; end $$;
revoke all on function public.message_here_lock() from public, anon, authenticated;
create or replace trigger messages_zz_here_lock before update of here_to on public.messages
  for each row when (new.here_to is distinct from old.here_to) execute function public.message_here_lock();

-- 5. Patches on live text: every anchor must be there exactly once, else stop (same as 372).
do $$
declare p record; d text; n text; i int; n_hits int;
begin
  for p in
    select * from (values
      ('public.unread_counts_for(public.channels[])', 'any(f.here_to)',
       array[
         $a$select m.content, m.reply_to_id from public.messages m$a$,
         $a$or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'$a$
       ],
       array[
         $a$select m.content, m.reply_to_id, m.here_to from public.messages m$a$,
         $a$or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
                              or auth.uid() = any(f.here_to)$a$
       ]),
      ('public.unread_counts_v1()', 'any(f.here_to)',
       array[
         $a$select m.content, m.reply_to_id from public.messages m$a$,
         $a$or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'$a$
       ],
       array[
         $a$select m.content, m.reply_to_id, m.here_to from public.messages m$a$,
         $a$or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
                              or auth.uid() = any(f.here_to)$a$
       ]),
      ('public.broadcast_message_change()', $a$'here_to', case when cardinality(new.here_to) <= 200 then new.here_to end$a$,
       array[
         $a$'restricted', restricted));$a$
       ],
       array[
         $a$'here_to', case when cardinality(new.here_to) <= 200 then new.here_to end,
        'restricted', restricted));$a$
       ])
    ) v(fn, marker, anchors, replacements)
  loop
    d := pg_get_functiondef(p.fn::regprocedure);
    continue when position(p.marker in d) > 0;          -- already patched
    n := d;
    for i in 1 .. array_length(p.anchors, 1) loop
      n_hits := (length(d) - length(replace(d, p.anchors[i], ''))) / length(p.anchors[i]);
      if n_hits <> 1 then raise exception '% changed: anchor % expected once, found % times. Read its live text again', p.fn, i, n_hits; end if;
      n := replace(n, p.anchors[i], p.replacements[i]);
    end loop;
    execute n;
  end loop;
end $$;

-- 6. The flag.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mention_here', '@here mentions', 'Ping the people who are online right now with @here, like @everyone but only for those online',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
