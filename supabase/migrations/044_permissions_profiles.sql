-- Discord-style granular permissions + profile customization.
-- UI is behind the 'perms' and 'profile' flags; the DB side keeps today's behaviour by default.

insert into public.feature_flags (key, label, description, mode) values
  ('perms', 'Granular permissions', 'Discord-style role permissions (kick, ban, manage channels, …)', 'off'),
  ('profile', 'Profile customization', 'Display name, pronouns and profile colors', 'off')
on conflict (key) do nothing;

-- ---------- Permissions ----------
alter table public.roles add column if not exists perms jsonb not null default '{}'::jsonb;
-- Defaults for members without a role that grants a basic permission (false = denied).
alter table public.servers add column if not exists everyone_perms jsonb not null default '{}'::jsonb;

/** Permissions every member has unless the server turns them off. */
create or replace function public.basic_perm(perm text)
returns boolean language sql immutable as $$
  select perm in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis', 'create_invite',
                  'change_nickname', 'connect', 'speak', 'create_polls', 'read_history');
$$;

/** What the old "Manage Server" / "Manage Messages" switches mean in the new model. */
create or replace function public.legacy_manage_server(perm text)
returns boolean language sql immutable as $$
  select perm in ('manage_server', 'manage_channels', 'manage_roles', 'manage_emojis', 'kick_members', 'ban_members',
                  'timeout_members', 'manage_nicknames', 'manage_messages', 'mention_everyone', 'mute_members', 'move_members');
$$;
create or replace function public.legacy_manage_messages(perm text)
returns boolean language sql immutable as $$
  select perm in ('manage_messages', 'timeout_members', 'manage_nicknames', 'mention_everyone', 'mute_members');
$$;

create or replace function public.server_perm(sid uuid, perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select sid is not null and (
    -- the owner can do everything
    exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (
      select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
      where mr.server_id = sid and mr.user_id = auth.uid()
        and (
          coalesce((r.perms->>'administrator')::boolean, false)
          or (r.manage_server and public.legacy_manage_server(perm))
          or (r.manage_messages and public.legacy_manage_messages(perm))
          or coalesce((r.perms->>perm)::boolean, false)
        )
    )
    -- basic permissions: every member has them unless the server says no (a role can still grant them above)
    or (public.basic_perm(perm)
        and public.is_server_member(sid)
        and coalesce(((select everyone_perms from public.servers where id = sid)->>perm)::boolean, true))
  );
$$;

/** Who can edit the permissions on a role: the owner, or someone with Manage Roles whose top role is above it. */
create or replace function public.can_edit_role(rid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.roles r join public.servers s on s.id = r.server_id where r.id = rid and s.owner_id = auth.uid())
    or exists (
      select 1 from public.roles r
      where r.id = rid and public.server_perm(r.server_id, 'manage_roles')
        and r.position < coalesce((select max(r2.position) from public.member_roles mr join public.roles r2 on r2.id = mr.role_id
                                   where mr.server_id = r.server_id and mr.user_id = auth.uid()), -1)
    );
$$;

-- Keep the two old switches in step with the new map so old clients keep working.
create or replace function public.roles_sync_legacy()
returns trigger language plpgsql as $$
begin
  if new.perms ? 'administrator' or new.perms ? 'manage_server' then
    new.manage_server := coalesce((new.perms->>'administrator')::boolean, false) or coalesce((new.perms->>'manage_server')::boolean, false);
  end if;
  if new.perms ? 'manage_messages' then
    new.manage_messages := coalesce((new.perms->>'manage_messages')::boolean, false) or new.manage_server;
  end if;
  -- Nobody can hand out more than they have.
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
drop trigger if exists roles_sync_legacy on public.roles;
create trigger roles_sync_legacy before insert or update on public.roles for each row execute function public.roles_sync_legacy();

-- Roles & role assignment: Manage Roles.
drop policy if exists "managers create roles" on public.roles;
create policy "managers create roles" on public.roles for insert to authenticated with check (public.server_perm(server_id, 'manage_roles'));
drop policy if exists "managers edit roles" on public.roles;
create policy "managers edit roles" on public.roles for update to authenticated using (public.server_perm(server_id, 'manage_roles')) with check (public.server_perm(server_id, 'manage_roles'));
drop policy if exists "managers delete roles" on public.roles;
create policy "managers delete roles" on public.roles for delete to authenticated using (public.server_perm(server_id, 'manage_roles'));
drop policy if exists "managers assign roles" on public.member_roles;
create policy "managers assign roles" on public.member_roles for insert to authenticated with check (public.server_perm(server_id, 'manage_roles'));
drop policy if exists "managers unassign roles" on public.member_roles;
create policy "managers unassign roles" on public.member_roles for delete to authenticated using (public.server_perm(server_id, 'manage_roles'));

-- Channels: Manage Channels.
drop policy if exists "managers edit channels" on public.channels;
create policy "managers edit channels" on public.channels for update to authenticated
  using (server_id is not null and public.server_perm(server_id, 'manage_channels'))
  with check (server_id is not null and public.server_perm(server_id, 'manage_channels'));
drop policy if exists "managers delete channels" on public.channels;
create policy "managers delete channels" on public.channels for delete to authenticated
  using (server_id is not null and public.server_perm(server_id, 'manage_channels'));

create or replace function public.create_channel(sid uuid, channel_name text, channel_kind text)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; k text := coalesce(channel_kind, 'text'); n text;
begin
  if not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  if k = 'voice' then
    n := left(nullif(regexp_replace(btrim(channel_name), '\s+', ' ', 'g'), ''), 100);
  else
    n := public.slugify_channel(channel_name);
  end if;
  if n is null then raise exception 'Channels need a name'; end if;
  if (select count(*) from public.channels where server_id = sid) >= 100 then raise exception 'Too many channels'; end if;
  insert into public.channels (kind, name, server_id, created_by, position)
    values (k, n, sid, auth.uid(), coalesce((select max(position) + 1 from public.channels where server_id = sid), 0))
    returning id into cid;
  return cid;
end;
$$;

create or replace function public.reorder_channels(sid uuid, ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t rearrange channels here'; end if;
  if not public.feature_on('reorder', sid) then raise exception 'Rearranging isn''t available here yet'; end if;
  for i in 1 .. coalesce(array_length(ids, 1), 0) loop
    update public.channels set position = i - 1 where id = ids[i] and server_id = sid;
  end loop;
end;
$$;

-- Emojis: Manage Emojis.
alter policy "add your own emojis" on public.emojis
  with check (owner_id = auth.uid() and server_id is not null and public.server_perm(server_id, 'manage_emojis'));
alter policy "rename your own emojis" on public.emojis
  using (server_id is not null and public.server_perm(server_id, 'manage_emojis'))
  with check (server_id is not null and public.server_perm(server_id, 'manage_emojis'));
alter policy "delete your own emojis" on public.emojis
  using (owner_id = auth.uid() or (server_id is not null and public.server_perm(server_id, 'manage_emojis')));

-- Invites: Create Invite.
drop policy if exists "members create invites" on public.invites;
create policy "members create invites" on public.invites for insert to authenticated
  with check (created_by = auth.uid() and public.server_perm(server_id, 'create_invite'));

-- Members: Kick / Ban / Timeout / Nicknames.
/** Same as server_perm but for someone else (used to protect admins from lower staff). */
create or replace function public.server_perm_user(sid uuid, uid uuid, perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = uid)
    or exists (
      select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
      where mr.server_id = sid and mr.user_id = uid
        and (coalesce((r.perms->>'administrator')::boolean, false) or (r.manage_server and public.legacy_manage_server(perm)) or coalesce((r.perms->>perm)::boolean, false))
    );
$$;

create or replace function public.kick_member(sid uuid, target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'kick_members') then raise exception 'You can''t kick people here'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then raise exception 'You can''t kick the owner'; end if;
  if public.server_perm_user(sid, target, 'administrator') and not exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    raise exception 'You can''t kick an administrator';
  end if;
  delete from public.server_members where server_id = sid and user_id = target;
  delete from public.invites where server_id = sid and created_by = target;
end;
$$;

create or replace function public.ban_member(sid uuid, target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'ban_members') then raise exception 'You can''t ban people here'; end if;
  if target = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then raise exception 'You can''t ban the owner'; end if;
  if public.server_perm_user(sid, target, 'administrator') and not exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    raise exception 'You can''t ban an administrator';
  end if;
  insert into public.server_bans (server_id, user_id, banned_by) values (sid, target, auth.uid()) on conflict do nothing;
  delete from public.server_members where server_id = sid and user_id = target;
  delete from public.invites where server_id = sid and created_by = target;
end;
$$;

create or replace function public.unban_member(sid uuid, target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'ban_members') then raise exception 'You can''t manage bans here'; end if;
  delete from public.server_bans where server_id = sid and user_id = target;
end;
$$;

create or replace function public.set_nickname(sid uuid, target uuid, nick text)
returns void language plpgsql security definer set search_path = public as $$
declare n text := nullif(trim(coalesce(nick, '')), '');
begin
  if not public.feature_on('nicknames', sid) then raise exception 'Nicknames aren''t available here yet'; end if;
  if target = auth.uid() then
    if not public.server_perm(sid, 'change_nickname') then raise exception 'You can''t change your nickname here'; end if;
  elsif not public.server_perm(sid, 'manage_nicknames') then
    raise exception 'You can''t change other people''s nicknames';
  end if;
  if n is not null and (public.bad_name(n) or public.has_adult_link(n)) then raise exception 'That nickname isn''t allowed.'; end if;
  update public.server_members set nickname = n where server_id = sid and user_id = target;
end;
$$;

-- Posting: Send Messages / Attach Files / Mention @everyone.
create or replace function public.can_post_channel(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select
      (c.server_id is null or public.server_perm(c.server_id, 'send_messages'))
      and (
        not c.read_only
        or public.server_perm(c.server_id, 'manage_server')
        or exists (
          select 1 from public.channel_post_roles cr
          join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
          where cr.channel_id = c.id
        )
      )
    from public.channels c where c.id = cid
  ), true);
$$;

create or replace function public.message_perm_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then return new; end if;
  if new.attachment_path is not null and not public.server_perm(sid, 'attach_files') then
    raise exception 'You can''t attach files here';
  end if;
  if new.content ~ '(^|[^A-Za-z0-9_@])@everyone\M' and not public.server_perm(sid, 'mention_everyone') then
    raise exception 'You can''t mention @everyone here';
  end if;
  if new.content ~* 'https?://' and not public.server_perm(sid, 'embed_links') then
    raise exception 'You can''t post links here';
  end if;
  return new;
end;
$$;
drop trigger if exists messages_perm_guard on public.messages;
create trigger messages_perm_guard before insert on public.messages for each row execute function public.message_perm_guard();

drop policy if exists "react as yourself" on public.reactions;
create policy "react as yourself" on public.reactions for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.can_access_channel(public.message_channel(message_id))
    and not public.dm_blocked(public.message_channel(message_id))
    and (
      (select c.server_id from public.channels c where c.id = public.message_channel(message_id)) is null
      or public.server_perm((select c.server_id from public.channels c where c.id = public.message_channel(message_id)), 'add_reactions')
    )
  );

-- Server-level defaults for the basic permissions (the @everyone row in the role editor).
create or replace function public.set_everyone_perms(sid uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'manage_roles') then raise exception 'You can''t edit permissions here'; end if;
  update public.servers set everyone_perms = coalesce(p, '{}'::jsonb) where id = sid;
end;
$$;
revoke all on function public.set_everyone_perms(uuid, jsonb) from public, anon;
grant execute on function public.set_everyone_perms(uuid, jsonb) to authenticated;

-- ---------- Profile customization ----------
alter table public.profiles
  add column if not exists display_name text,
  add column if not exists pronouns text,
  add column if not exists accent_color text,
  add column if not exists accent_color2 text;

create or replace function public.profile_custom_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.display_name := nullif(left(btrim(coalesce(new.display_name, '')), 32), '');
  new.pronouns := nullif(left(btrim(coalesce(new.pronouns, '')), 40), '');
  if new.display_name is not null and (public.bad_name(new.display_name) or public.has_adult_link(new.display_name) or public.brand_name(new.display_name)) then
    raise exception 'That display name isn''t allowed';
  end if;
  if new.pronouns is not null and public.bad_name(new.pronouns) then raise exception 'Those pronouns aren''t allowed'; end if;
  if new.accent_color is not null and new.accent_color !~ '^#[0-9a-fA-F]{6}$' then new.accent_color := null; end if;
  if new.accent_color2 is not null and new.accent_color2 !~ '^#[0-9a-fA-F]{6}$' then new.accent_color2 := null; end if;
  return new;
end;
$$;
drop trigger if exists profiles_custom_guard on public.profiles;
create trigger profiles_custom_guard before insert or update on public.profiles for each row execute function public.profile_custom_guard();

-- Timeouts: Timeout Members. Voice mutes: Mute Members.
create or replace function public.server_timeout(sid uuid, target uuid, minutes int, why text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'timeout_members') then raise exception 'You can''t time people out here'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then raise exception 'You can''t time out the owner'; end if;
  if public.is_staff_user(target) then raise exception 'You can''t time out Yapper staff'; end if;
  if public.server_perm_user(sid, target, 'administrator') and not exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    raise exception 'You can''t time out an administrator';
  end if;
  if minutes <= 0 then
    delete from public.server_timeouts where server_id = sid and user_id = target;
    return;
  end if;
  if minutes > 10080 then raise exception 'Timeouts are up to 7 days'; end if;
  insert into public.server_timeouts (server_id, user_id, until, reason, set_by)
  values (sid, target, now() + make_interval(mins => minutes), left(coalesce(why, ''), 200), auth.uid())
  on conflict (server_id, user_id) do update set until = excluded.until, reason = excluded.reason, set_by = excluded.set_by, created_at = now();
end;
$$;

create or replace function public.voice_timeout(uid uuid, vchannel uuid, minutes int)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.channels where id = vchannel;
  if not (public.is_site_admin() or (sid is not null and public.server_perm(sid, 'mute_members'))) then raise exception 'Not allowed'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t mute an admin'; end if;
  update public.profiles set voice_muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end where id = uid;
end;
$$;
