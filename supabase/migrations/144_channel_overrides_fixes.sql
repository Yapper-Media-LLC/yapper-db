-- 144: security review fixes for channel overrides (142, flag channel_perms). Re-runnable.
--  * Moving a channel in or out of a category with overrides, or removing such a category, used to
--    skip the override guard (Manage Channels could unhide a channel, or spread a category's allows).
--  * Bots' message / reaction events, bot_visible_channels and the starboard only treated `private`
--    channels as hidden; they now also respect overrides.
--  * Removing a server no longer trips the guard when the overrides cascade runs first.
--  * Read Message History can't be set as an override yet (not enforced everywhere).

set lock_timeout = '5s';

-- Flag on for the channel's server AND the channel or its category has overrides. Cheap: one flag row,
-- then an index probe on an (almost always) empty table.
create or replace function public.channel_overrides_live(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
       and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
    from public.channels c where c.id = cid), false);
$$;
revoke all on function public.channel_overrides_live(uuid) from public, anon, authenticated;

-- ---------- Guard: server removal cascade, no read_history ----------
do $$ declare d text; begin
  d := pg_get_functiondef('public.channel_overrides_guard()'::regprocedure);
  if position('server removal' in d) = 0 then
    d := replace(d, E'  if tg_op = ''DELETE'' then\n    if (old.channel_id is not null',
      E'  if tg_op = ''DELETE'' then\n    -- server removal: the cascade can reach this table before channels / categories\n'
      || E'    if not exists (select 1 from public.servers where id = old.server_id) then return old; end if;\n'
      || E'    if (old.channel_id is not null');
    d := replace(d, E'    new.server_id := sid;\n',
      E'    new.server_id := sid;\n'
      || E'    if ''read_history'' = any(new.allow || new.deny) then raise exception ''Read Message History can''''t be set per channel yet''; end if;\n');
    if position('server removal' in d) = 0 or position('Read Message History' in d) = 0 then
      raise exception 'channel_overrides_guard patch did not apply';
    end if;
    execute d;
  end if;
end $$;

-- ---------- Moving channels between categories ----------
create or replace function public.channel_category_move_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); sid uuid := new.server_id; p text;
begin
  -- Same server only (direct updates and the bot API didn't check), and a channel can't change server.
  if new.server_id is distinct from old.server_id then raise exception 'Channels can''t move to another server'; end if;
  if new.category_id is not null and not exists (select 1 from public.channel_categories where id = new.category_id and server_id = new.server_id) then
    raise exception 'That category isn''t in this server';
  end if;
  if me is null or sid is null or new.category_id is not distinct from old.category_id then return new; end if;
  -- The category itself is being removed (category_id set null by the cascade): its own guard ran.
  if new.category_id is null and not exists (select 1 from public.channel_categories where id = old.category_id) then return new; end if;
  if not exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                 and (f.mode = 'everyone' or (f.mode = 'test' and sid = any(f.servers)))) then return new; end if;
  if not exists (select 1 from public.channel_overrides o where o.category_id = old.category_id or o.category_id = new.category_id) then return new; end if;
  if exists (select 1 from public.servers s where s.id = sid and s.owner_id = me) or public.server_perm(sid, 'administrator') then return new; end if;
  -- Leaving a category that hides the channel from someone unhides it.
  if old.category_id is not null and not public.server_perm(sid, 'manage_server')
     and exists (select 1 from public.channel_overrides o where o.category_id = old.category_id and 'view_channel' = any(o.deny)) then
    raise exception 'You need Manage Server to move a channel out of a category that hides it';
  end if;
  -- Leaving drops the category's other settings too (e.g. a deny of Send Messages): only with that permission here.
  if old.category_id is not null then
    for p in select distinct x from public.channel_overrides o, unnest(o.allow || o.deny) x where o.category_id = old.category_id and x <> 'view_channel' loop
      if not public.channel_perm(new.id, p) then
        raise exception 'That category sets permissions you don''t have yourself in this channel';
      end if;
    end loop;
  end if;
  -- Joining a category takes on its overrides: same rule as setting them by hand.
  if new.category_id is not null then
    for p in select distinct x from public.channel_overrides o, unnest(o.allow || o.deny) x where o.category_id = new.category_id loop
      if p = 'view_channel' then
        if not public.server_perm(sid, 'manage_server')
           and exists (select 1 from public.channel_overrides o where o.category_id = new.category_id and 'view_channel' = any(o.allow)) then
          raise exception 'You need Manage Server to move a channel into that category';
        end if;
      elsif not public.server_perm(sid, p) then
        raise exception 'That category sets permissions you don''t have yourself';
      end if;
    end loop;
  end if;
  return new;
end $$;
revoke all on function public.channel_category_move_guard() from public, anon, authenticated;

create or replace trigger channels_category_move_guard
  before update of category_id, server_id on public.channels
  for each row execute function public.channel_category_move_guard();

-- ---------- Removing a category that has overrides ----------
create or replace function public.channel_category_remove_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or not exists (select 1 from public.servers where id = old.server_id) then return old; end if;
  if not exists (select 1 from public.channel_overrides o where o.category_id = old.id) then return old; end if;
  if exists (select 1 from public.servers s where s.id = old.server_id and s.owner_id = me)
     or public.server_perm(old.server_id, 'administrator') or public.server_perm(old.server_id, 'manage_server') then
    return old;
  end if;
  raise exception 'This category has its own permissions. You need Manage Server to remove it';
end $$;
revoke all on function public.channel_category_remove_guard() from public, anon, authenticated;

create or replace trigger channel_categories_remove_guard
  before delete on public.channel_categories
  for each row execute function public.channel_category_remove_guard();

-- ---------- Bots and starboard respect overrides ----------
do $$ declare d text; begin
  d := pg_get_functiondef('public.bot_webhooks()'::regprocedure);
  if position('channel_overrides_live' in d) = 0 then
    d := replace(d, 'declare sid uuid;', 'declare live boolean; sid uuid;');
    d := replace(d, E'  for b in select bo.id', E'  live := public.channel_overrides_live(new.channel_id);\n  for b in select bo.id');
    d := replace(d, 'if coalesce(priv, false) and not public.bot_channel_visible', 'if (coalesce(priv, false) or live) and not public.bot_channel_visible');
    if position('or live) and' in d) = 0 or position('live := ' in d) = 0 then raise exception 'bot_webhooks patch did not apply'; end if;
    execute d;
  end if;

  d := pg_get_functiondef('public.bot_reaction_events()'::regprocedure);
  if position('channel_overrides_live' in d) = 0 then
    d := replace(d, 'declare r record', 'declare live boolean; r record');
    d := replace(d, E'  for b in select bo.id', E'  live := public.channel_overrides_live(cid);\n  for b in select bo.id');
    d := replace(d, 'if coalesce(priv, false) and not public.bot_channel_visible', 'if (coalesce(priv, false) or live) and not public.bot_channel_visible');
    if position('or live) and' in d) = 0 or position('live := ' in d) = 0 then raise exception 'bot_reaction_events patch did not apply'; end if;
    execute d;
  end if;

  d := pg_get_functiondef('public.bot_visible_channels(uuid, uuid)'::regprocedure);
  if position('channel_overrides_live' in d) = 0 then
    d := replace(d, '(not c.private or public.bot_channel_visible(bid, c.id))',
                    '((not c.private and not public.channel_overrides_live(c.id)) or public.bot_channel_visible(bid, c.id))');
    if position('channel_overrides_live' in d) = 0 then raise exception 'bot_visible_channels patch did not apply'; end if;
    execute d;
  end if;

  -- Starboard posts into a channel everyone sees: skip channels an override hides from anyone.
  d := pg_get_functiondef('public.starboard_react()'::regprocedure);
  if position('channel_overrides_live' in d) = 0 then
    d := replace(d, E'  if ch.server_id is null or ch.private then return null; end if;\n',
      E'  if ch.server_id is null or ch.private then return null; end if;\n'
      || E'  if public.channel_overrides_live(ch.id) and exists (select 1 from public.channel_overrides o\n'
      || E'       where (o.channel_id = ch.id or o.category_id = ch.category_id) and ''view_channel'' = any(o.deny)) then return null; end if;\n');
    if position('channel_overrides_live' in d) = 0 then raise exception 'starboard_react patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- ---------- Realtime: subscribe check that also says which server ----------
-- ops/realtime asks this when someone subscribes to chan:<id>: the server id (or 'dm') when they may
-- see it, null when not. Knowing the server keeps its access re-checks scoped to that server.
create or replace function public.channel_access_server(cid uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when public.can_access_channel(cid) then coalesce((select server_id::text from public.channels where id = cid), 'dm') end;
$$;
revoke all on function public.channel_access_server(uuid) from public, anon;
grant execute on function public.channel_access_server(uuid) to authenticated;
