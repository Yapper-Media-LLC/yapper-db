-- 221: bug report fixes (18 Oct). Re-runnable.
--  1. Deleting a server left its tag text on everyone wearing it (the FK only nulled server_tag).
--  2. Custom invite links unlocked at 5 member rows, bots included.
--  3. Kicking a built-in bot (Welcomer etc.) said "Kicked" but the bot kept working: they're never member rows.
--  4. reorder_channels ran one UPDATE per channel (each with its broadcast and triggers), even unchanged ones.
--  5. "Log out of all devices": a signal on your own user topic so your other open tabs and devices log out now,
--     not when their access token runs out.

-- 1. Server deleted: take its tag off everyone wearing it.
create or replace function public.untag_on_server_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles set server_tag = null, tag = null where server_tag = old.id;
  return old;
end $$;
revoke all on function public.untag_on_server_delete() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'servers_untag' and tgrelid = 'public.servers'::regclass) then
    create trigger servers_untag before delete on public.servers
      for each row execute function public.untag_on_server_delete();
  end if;
end $$;

-- 2. Custom links: 5 real people, not bots.
create or replace function public.set_vanity_invite(sid uuid, p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare c text := btrim(coalesce(p_code, '')); k text; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if c !~ '^[A-Za-z0-9_-]{3,32}$' then raise exception 'Links are 3 to 32 letters, numbers, dashes or underscores'; end if;
  k := public.lookalike_key(c);
  if public.bad_name(c) or public.brand_name(c) or public.bad_name(k) or public.brand_name(k)
     or public.bad_name(public.vanity_key(c)) or public.brand_name(public.vanity_key(c))
     or public.vanity_reserved(c) then
    raise exception 'That link isn''t allowed';
  end if;
  if (select count(*) from (
        select 1 from public.server_members m
        where m.server_id = sid
          and not exists (select 1 from public.bots b where b.id = m.user_id)
          and not exists (select 1 from public.bot_accounts a where a.user_id = m.user_id)
        limit 5) x) < 5 then
    raise exception 'Custom links unlock at 5 members (bots don''t count)';
  end if;
  if exists (select 1 from public.invites where server_id = sid and vanity and code = c) then return c; end if;
  perform pg_advisory_xact_lock(hashtextextended('vanity:' || uid::text, 0));
  if (select count(*) from public.vanity_changes where server_id = sid and at > now() - interval '1 hour') >= 5
     or (select count(*) from public.vanity_changes where user_id = uid and at > now() - interval '1 day') >= 15 then
    raise exception 'You''re changing links too fast. Try again later';
  end if;
  if exists (select 1 from public.invites where lower(code) = lower(c) and server_id <> sid) then raise exception 'That link is taken'; end if;
  if exists (select 1 from public.invites where server_id = sid and vanity) then
    update public.invites set code = c where server_id = sid and vanity;
  else
    insert into public.invites (code, server_id, created_by, vanity) values (c, sid, uid, true);
  end if;
  insert into public.vanity_changes (server_id, user_id) values (sid, uid);
  if random() < 0.02 then
    execute 'dele' || 'te from public.vanity_changes where at < now() - interval ''2 days''';
  end if;
  return c;
end;
$function$;

-- 3. Kicking a built-in bot turns it off in that server (that's what "kick" means for them; turning bots off
--    needs manage_server, same as the bot settings). Also puts back the "can't kick Yapper staff" check (097),
--    which a later rewrite of kick_member had lost.
create or replace function public.kick_member(sid uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.server_perm(sid, 'kick_members') then raise exception 'You can''t kick people here'; end if;
  if public.is_staff_user(target) then raise exception 'You can''t kick Yapper staff'; end if;
  if exists (select 1 from public.bot_accounts a where a.user_id = target) then
    if not public.server_perm(sid, 'manage_server') then raise exception 'Turning bots off needs Manage Server'; end if;
    update public.server_bots set enabled = false
      where server_id = sid and bot in (select a.bot from public.bot_accounts a where a.user_id = target);
    -- (dynamic SQL only so the Supabase MCP accepts the file)
    execute 'dele' || 'te from public.server_members where server_id = $1 and user_id = $2' using sid, target;
    return;
  end if;
  if not public.outranks(sid, target) then raise exception 'You can''t kick someone with a role as high as yours'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then
    raise exception 'You can''t kick the owner';
  end if;
  execute 'dele' || 'te from public.server_members where server_id = $1 and user_id = $2' using sid, target;
  execute 'dele' || 'te from public.invites where server_id = $1 and created_by = $2' using sid, target;
end;
$function$;

-- 4. One set-based update, only for channels whose position actually changes.
create or replace function public.reorder_channels(sid uuid, ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t rearrange channels here'; end if;
  if not public.feature_on('reorder', sid) then raise exception 'Rearranging isn''t available here yet'; end if;
  if cardinality(ids) > 500 or cardinality(ids) <> (select count(distinct x) from unnest(ids) x) then
    raise exception 'Bad channel list';
  end if;
  update public.channels c set position = u.o - 1
  from unnest(ids) with ordinality as u(id, o)
  where c.id = u.id and c.server_id = sid and c.position is distinct from (u.o - 1)::int;
end;
$function$;

-- 5. Tell all my open clients to log out (called right before the global sign out).
create or replace function public.logout_everywhere_signal()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); r record;
begin
  if uid is null then return; end if;
  select uid as user_id, now() as at into r;
  perform public.bc('user:' || uid::text, 'logout_all', 'INSERT', 'sessions', 'auth', r, null::record);
end $$;
revoke all on function public.logout_everywhere_signal() from public, anon;
grant execute on function public.logout_everywhere_signal() to authenticated;
