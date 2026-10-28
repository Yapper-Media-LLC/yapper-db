-- 504: giving someone a role also gives them its permissions, so a non-owner can only give a role whose permissions
-- they have themselves (Administrator only if they have Administrator). Before, the only check was "below your
-- highest role", so someone with just Manage Roles could hand out an Administrator role that sat under their top
-- role, by hand, through a reaction role, or (other powers) as a Levels reward. Making and editing roles already had
-- this rule; giving one now matches it. Owners, site admins and people with Administrator are unchanged.
-- Found while checking the 25 Oct report of an OWNER role "appearing" on an alt (that one was the server owner's
-- own click: owners can give any role, which stays so).
-- Also: role permissions must be true/false. Postgres reads "yes", "t", "1" as true, so a string value was a way
-- past the "you can't give a permission you don't have" loops (0 such values live on 25 Oct).
-- role_guard, roles_sync_legacy, set_reaction_roles and set_server_bot are the live bodies of 25 Oct with only the
-- lines marked 504 changed. Re-runnable.

-- Stop if one of the four copied functions was changed live after 25 Oct (it would be silently undone here).
-- Passes on the 25 Oct bodies and on 504's own (re-run).
do $$
declare f record;
begin
  for f in select * from (values ('role_guard', '534c4b81bbd7e7b5433fd49b75c4a40d'), ('roles_sync_legacy', '7da0d9b0084d17006a8fdd642450f138'),
                                 ('set_reaction_roles', 'b16f828d5147bd959c3399fe03412335'), ('set_server_bot', '777ee080227c60f50452f6ed4d87a755')) v(name, sum) loop
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.name
               and md5(p.prosrc) <> f.sum and position('504:' in p.prosrc) = 0) then
      raise exception '504: public.% changed since 25 Oct. Ask Claude to redo 504 on top of the live version.', f.name;
    end if;
  end loop;
end $$;

-- Can I give this role to someone, permission-wise? (Rank is checked by the callers.)
create or replace function public.can_give_role_perms(sid uuid, rid uuid)
returns boolean language plpgsql stable set search_path = public as $$
declare rp jsonb; rms boolean; rmm boolean; k text;
begin
  if exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) or public.is_site_admin()
     or public.server_perm(sid, 'administrator') then
    return true;
  end if;
  select perms, manage_server, manage_messages into rp, rms, rmm from public.roles where id = rid and server_id = sid;
  if not found then return false; end if;
  -- The legacy Manage Server switch needs Administrator, as when editing a role.
  if coalesce(rms, false) then return false; end if;
  if coalesce(rmm, false) and not public.server_perm(sid, 'manage_messages') then return false; end if;
  -- Anything not plainly false counts (Administrator included: we know they don't have it).
  for k in select key from jsonb_each(coalesce(rp, '{}'::jsonb)) where value not in ('false'::jsonb, 'null'::jsonb) loop
    if not public.server_perm(sid, k) then return false; end if;
  end loop;
  return true;
end; $$;
revoke all on function public.can_give_role_perms(uuid, uuid) from public, anon;
grant execute on function public.can_give_role_perms(uuid, uuid) to authenticated, service_role;

create or replace function public.role_guard()
returns trigger language plpgsql set search_path = public as $$
declare sid uuid; top int; pos int; k text;
begin
  if current_user <> 'authenticated' or current_setting('yapper.bot', true) = '1' then return coalesce(new, old); end if;
  sid := coalesce(new.server_id, old.server_id);
  if exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) or public.is_site_admin() then
    return coalesce(new, old);
  end if;
  top := public.my_top_role_position(sid);
  if tg_table_name = 'member_roles' then
    select position into pos from public.roles where id = coalesce(new.role_id, old.role_id);
    if pos is null or pos >= top then raise exception 'You can only give or take roles below your highest role'; end if;
    -- 504: and only roles whose permissions you have yourself. Taking a role away stays as it was.
    if tg_op = 'INSERT' and not public.can_give_role_perms(sid, new.role_id) then
      raise exception 'You can''t give out a role with permissions you don''t have yourself';
    end if;
    return coalesce(new, old);
  end if;
  if tg_op in ('UPDATE', 'DELETE') and old.position >= top then
    raise exception 'You can only change roles below your highest role';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'INSERT' and new.position >= top then new.position := top - 1; end if;
  if new.position >= top then raise exception 'Roles have to stay below your highest role'; end if;
  if coalesce((new.perms ->> 'administrator')::boolean, false)
     and (tg_op = 'INSERT' or not coalesce((old.perms ->> 'administrator')::boolean, false)) then
    raise exception 'Only the owner can grant Administrator';
  end if;
  if new.manage_server and (tg_op = 'INSERT' or not old.manage_server) and not public.server_perm(sid, 'administrator') then
    raise exception 'You can''t grant Manage Server';
  end if;
  if new.manage_messages and (tg_op = 'INSERT' or not old.manage_messages) and not public.server_perm(sid, 'manage_messages') then
    raise exception 'You can''t grant Manage Messages';
  end if;
  -- 504: every value that isn't plainly false (was: only the json value true, so "yes" slipped past).
  for k in select key from jsonb_each(coalesce(new.perms, '{}'::jsonb)) where value not in ('false'::jsonb, 'null'::jsonb) loop
    if (tg_op = 'INSERT' or not coalesce((old.perms ->> k)::boolean, false)) and not public.server_perm(sid, k) then
      raise exception 'You can''t give a permission you don''t have (%)', k;
    end if;
  end loop;
  return new;
end; $$;

create or replace function public.roles_sync_legacy()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  -- 504: permissions are true or false, nothing else ("yes" reads as true in the permission checks).
  if jsonb_typeof(coalesce(new.perms, '{}'::jsonb)) <> 'object'
     or exists (select 1 from jsonb_each(coalesce(new.perms, '{}'::jsonb)) where jsonb_typeof(value) <> 'boolean') then
    raise exception 'Role permissions have to be true or false';
  end if;
  -- The old manage_server / manage_messages switches each imply a bundle of permissions.
  -- They are no longer raised from the new per-permission list, so switching one permission off
  -- (which turns the old switch off and spells out the rest) sticks.
  if tg_op = 'UPDATE' and new.perms is distinct from old.perms and not public.can_edit_role(new.id) then
    raise exception 'You can''t edit this role''s permissions';
  end if;
  if tg_op = 'UPDATE' and coalesce((new.perms->>'administrator')::boolean, false) and not coalesce((old.perms->>'administrator')::boolean, false)
     and not exists (select 1 from public.servers where id = new.server_id and owner_id = auth.uid())
     and not public.server_perm(new.server_id, 'administrator') then
    raise exception 'Only the owner or an administrator can grant Administrator';
  end if;
  return new;
end;
$$;

create or replace function public.set_reaction_roles(mid uuid, pairs jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; p jsonb; top int; e text;
begin
  select c.server_id into sid from public.messages m join public.channels c on c.id = m.channel_id where m.id = mid;
  if sid is null or not public.server_perm(sid, 'manage_roles') then raise exception 'You can''t manage roles here'; end if;
  if not public.feature_on('reaction_roles', sid) then raise exception 'Reaction roles aren''t available here yet'; end if;
  if jsonb_typeof(pairs) <> 'array' or jsonb_array_length(pairs) > 20 then raise exception 'Up to 20 reaction roles per message'; end if;
  top := public.my_top_role_position(sid);
  -- (Emoji up to 80 characters now, was left(p ->> 'emoji', 80) in an older patch: keep that text here so it skips.)
  for p in select * from jsonb_array_elements(pairs) loop
    e := btrim(coalesce(p ->> 'emoji', ''));
    if not public.reaction_emoji_ok(e)
       and not exists (select 1 from public.reaction_roles rr where rr.message_id = mid and rr.emoji = e) then
      raise exception 'Each reaction role needs a single emoji';
    end if;
  end loop;
  perform public.clear_reaction_roles(mid);
  for p in select * from jsonb_array_elements(pairs) loop
    -- 504: below your top role AND only permissions you have (the reaction hands it out with yapper.bot set).
    if not exists (select 1 from public.roles r where r.id = (p ->> 'role_id')::uuid and r.server_id = sid
                   and ((r.position < top and public.can_give_role_perms(sid, r.id))
                        or exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid()) or public.is_site_admin())) then
      raise exception 'You can only hand out roles below your highest role, with permissions you have yourself';
    end if;
    insert into public.reaction_roles (message_id, emoji, role_id, server_id) values (mid, btrim(p ->> 'emoji'), (p ->> 'role_id')::uuid, sid)
      on conflict (message_id, emoji) do update set role_id = excluded.role_id;
  end loop;
end; $$;

create or replace function public.set_server_bot(sid uuid, p_bot text, p_enabled boolean, p_config jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare cfg jsonb := coalesce(p_config, '{}'::jsonb);
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can set up bots'; end if;
  if not public.feature_on('bots', sid) then raise exception 'Bots aren''t available here yet'; end if;
  -- The per-server look (name, picture) is set by set_bot_look and the upload route; keep what's stored.
  cfg := cfg - 'look_name' - 'look_avatar';
  cfg := cfg || coalesce((select jsonb_strip_nulls(jsonb_build_object('look_name', config -> 'look_name', 'look_avatar', config -> 'look_avatar')) from public.server_bots where server_id = sid and bot = p_bot), '{}'::jsonb);
  if not public.server_plus_on(sid) then
    cfg := cfg - 'xp_mult' - 'rewards' - 'lines' - 'leave_channel_id' - 'leave_message' - 'commands'
      - 'member_channel_id' - 'ignore' - 'emoji' - 'self_star' - 'required_role_id' - 'support_role_id' - 'welcome' - 'transcript';
    if p_bot = 'levels' then cfg := cfg - 'message'; end if;
  end if;
  if jsonb_typeof(cfg -> 'rewards') = 'array' and jsonb_array_length(cfg -> 'rewards') > 20 then raise exception 'Up to 20 role rewards'; end if;
  -- 504: reward roles also need permissions the setter has (Levels hands them out with yapper.bot set).
  if jsonb_typeof(cfg -> 'rewards') = 'array'
     and not exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid())
     and not public.is_site_admin()
     and exists (
       select 1 from jsonb_array_elements(cfg -> 'rewards') rw
       left join public.roles r on r.id = case when (rw ->> 'role_id') ~ '^[0-9a-f-]{36}$' then (rw ->> 'role_id')::uuid end
       where rw ? 'role_id' and (r.id is null or r.server_id <> sid
              or r.position >= public.my_top_role_position(sid)
              or coalesce((r.perms ->> 'administrator')::boolean, false)
              or not public.can_give_role_perms(sid, r.id))) then
    raise exception 'Role rewards have to be roles below your highest role, with permissions you have yourself';
  end if;
  if jsonb_typeof(cfg -> 'commands') = 'array' and jsonb_array_length(cfg -> 'commands') > 25 then raise exception 'Up to 25 custom commands'; end if;
  if jsonb_typeof(cfg -> 'lines') = 'array' and jsonb_array_length(cfg -> 'lines') > 10 then raise exception 'Up to 10 welcome lines'; end if;
  if jsonb_typeof(cfg -> 'ignore') = 'array' and jsonb_array_length(cfg -> 'ignore') > 25 then raise exception 'Up to 25 ignored channels'; end if;
  if cfg ? 'emoji' and char_length(cfg ->> 'emoji') > 16 then raise exception 'Pick one emoji'; end if;
  if p_bot = 'tickets' and jsonb_typeof(cfg -> 'panels') = 'array' and jsonb_array_length(cfg -> 'panels') > (case when public.server_plus_on(sid) then 10 else 2 end) then
    raise exception '%', (case when public.server_plus_on(sid) then 'Up to 10 ticket panels' else 'Free servers get 2 ticket panels. Tickets+ gets 10.' end);
  end if;
  insert into public.server_bots (server_id, bot, enabled, config) values (sid, p_bot, p_enabled, cfg)
  on conflict (server_id, bot) do update set enabled = excluded.enabled, config = excluded.config;
end $$;

-- The app side (flag role_give_confirm, test): giving someone a role with Administrator or other big powers asks
-- first ("Give @x the OWNER role? It has Administrator..."), in the profile card, Server Settings, Members and a
-- role's Manage Members. A one-click list with the strongest role first is how the owner's OWNER grant happened.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('role_give_confirm', 'Ask before giving a powerful role', 'Giving someone a role with Administrator, Manage Server, Manage Roles, Ban or Kick asks first', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
