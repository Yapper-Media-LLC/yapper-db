-- Server audit log (flag audit_log): who changed what in a server, like Discord's Audit Log.
-- Server Settings > Audit Log. The owner, admins, Manage Server roles and roles with the new
-- "View Audit Log" permission can read it. Rows come from AFTER triggers on the server tables; they only
-- fire on changes (no per-message work), never block the change (errors are swallowed), skip system and
-- bulk work (no auth.uid(), or yapper.bulk = '1') and skip rows whose server is already gone (cascades).
-- Kept 90 days.

create table if not exists public.server_audit_log (
  id bigint generated always as identity primary key,
  server_id uuid not null references public.servers(id) on delete cascade,
  actor_id uuid,
  action text not null,
  target_kind text,
  target_id uuid,
  target_name text,
  extra jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists server_audit_log_server_idx on public.server_audit_log (server_id, id desc);
create index if not exists server_audit_log_created_idx on public.server_audit_log (created_at);
alter table public.server_audit_log enable row level security;
-- No policies: read only through server_audit_list().
revoke all on public.server_audit_log from anon, authenticated;

-- One row. Internal: only the triggers call it.
create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid();
begin
  if actor is null or sid is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return; end if;
  if not exists (select 1 from public.servers where id = sid) then return; end if;
  if not public.feature_on('audit_log', sid) then return; end if;
  -- Yapper staff acting on a server they don't run (takedowns, hiding from Discover) stay out of its log.
  if public.is_staff_user(actor) and not public.server_perm(sid, 'manage_server') then return; end if;
  insert into public.server_audit_log (server_id, actor_id, action, target_kind, target_id, target_name, extra)
  values (sid, actor, act, kind, tid, left(tname, 100), coalesce(extra, '{}'::jsonb));
end $$;
revoke execute on function public.audit_add(uuid, text, text, uuid, text, jsonb) from public, anon, authenticated;

-- {k, from, to} for each listed column that changed.
create or replace function public.audit_diff(o jsonb, n jsonb, keys text[])
returns jsonb language sql immutable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('k', k, 'from', o -> k, 'to', n -> k)), '[]'::jsonb)
  from unnest(keys) k where (o -> k) is distinct from (n -> k);
$$;

-- Channels: made, deleted, changed (name, private, read only, slowmode, no images, category).
create or replace function public.audit_channels() returns trigger language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  -- Tickets open and close all day: not worth a line each.
  if coalesce(new.ticket_by, old.ticket_by) is not null then return null; end if;
  if tg_op = 'INSERT' then
    if new.server_id is not null then
      perform public.audit_add(new.server_id, 'channel_create', 'channel', new.id, new.name, jsonb_build_object('kind', new.kind));
    end if;
  elsif tg_op = 'DELETE' then
    if old.server_id is not null then
      perform public.audit_add(old.server_id, 'channel_delete', 'channel', old.id, old.name, jsonb_build_object('kind', old.kind));
    end if;
  elsif new.server_id is not null then
    -- A deleted category clears category_id on its channels (cascade): that's not a channel edit.
    if pg_trigger_depth() > 1 and new.category_id is null and old.category_id is not null then return null; end if;
    d := public.audit_diff(to_jsonb(old), to_jsonb(new), array['name', 'private', 'read_only', 'slowmode', 'no_images', 'category_id']);
    if jsonb_array_length(d) > 0 then
      perform public.audit_add(new.server_id, 'channel_update', 'channel', new.id, new.name, jsonb_build_object('changes', d));
    end if;
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger channels_audit after insert or delete or update of name, private, read_only, slowmode, no_images, category_id
  on public.channels for each row execute function public.audit_channels();

-- Roles: made, deleted, changed (name, colour, permissions turned on/off, mentionable).
create or replace function public.audit_roles() returns trigger language plpgsql security definer set search_path = public as $$
declare op jsonb; np jsonb; on_list text[]; off_list text[]; d jsonb;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if tg_op = 'INSERT' then
    perform public.audit_add(new.server_id, 'role_create', 'role', new.id, new.name, '{}'::jsonb);
  elsif tg_op = 'DELETE' then
    perform public.audit_add(old.server_id, 'role_delete', 'role', old.id, old.name, '{}'::jsonb);
  else
    op := coalesce(old.perms, '{}'::jsonb) || jsonb_build_object('manage_server', old.manage_server or coalesce((old.perms ->> 'manage_server')::boolean, false),
      'manage_messages', old.manage_messages or coalesce((old.perms ->> 'manage_messages')::boolean, false));
    np := coalesce(new.perms, '{}'::jsonb) || jsonb_build_object('manage_server', new.manage_server or coalesce((new.perms ->> 'manage_server')::boolean, false),
      'manage_messages', new.manage_messages or coalesce((new.perms ->> 'manage_messages')::boolean, false));
    select array_agg(k order by k) into on_list from jsonb_object_keys(np) k
      where coalesce((np ->> k)::boolean, false) and not coalesce((op ->> k)::boolean, false);
    select array_agg(k order by k) into off_list from jsonb_object_keys(op) k
      where coalesce((op ->> k)::boolean, false) and not coalesce((np ->> k)::boolean, false);
    d := public.audit_diff(to_jsonb(old), to_jsonb(new), array['name', 'color', 'color2', 'mentionable']);
    if on_list is null and off_list is null and jsonb_array_length(d) = 0 then return null; end if;
    perform public.audit_add(new.server_id, 'role_update', 'role', new.id, new.name,
      jsonb_build_object('changes', d, 'on', coalesce(to_jsonb(on_list), '[]'::jsonb), 'off', coalesce(to_jsonb(off_list), '[]'::jsonb)));
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger roles_audit after insert or delete or update of name, color, color2, perms, manage_server, manage_messages, mentionable
  on public.roles for each row execute function public.audit_roles();

-- Roles given and taken. Rows going away because the member left or the role was deleted aren't logged.
create or replace function public.audit_member_roles() returns trigger language plpgsql security definer set search_path = public as $$
declare rname text;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if tg_op = 'INSERT' then
    select name into rname from public.roles where id = new.role_id;
    perform public.audit_add(new.server_id, 'member_role_add', 'user', new.user_id, null, jsonb_build_object('role_id', new.role_id, 'role', rname));
  else
    -- Rows going away because the member left or the role was deleted come from a cascade.
    if pg_trigger_depth() > 1 then return null; end if;
    select name into rname from public.roles where id = old.role_id;
    if rname is null then return null; end if;
    if not exists (select 1 from public.server_members where server_id = old.server_id and user_id = old.user_id) then return null; end if;
    perform public.audit_add(old.server_id, 'member_role_remove', 'user', old.user_id, null, jsonb_build_object('role_id', old.role_id, 'role', rname));
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger member_roles_audit after insert or delete on public.member_roles
  for each row execute function public.audit_member_roles();

-- Bans and unbans.
create or replace function public.audit_bans() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if tg_op = 'INSERT' then
    perform public.audit_add(new.server_id, 'member_ban', 'user', new.user_id, null, '{}'::jsonb);
  else
    perform public.audit_add(old.server_id, 'member_unban', 'user', old.user_id, null, '{}'::jsonb);
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger server_bans_audit after insert or delete on public.server_bans
  for each row execute function public.audit_bans();

-- Kicks: someone else took the member out, and it wasn't a ban (ban_member adds the ban first).
create or replace function public.audit_kicks() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if auth.uid() is null or auth.uid() = old.user_id then return null; end if;
  if exists (select 1 from public.server_bans where server_id = old.server_id and user_id = old.user_id) then return null; end if;
  -- Removing a bot already logs bot_remove.
  if exists (select 1 from public.bots where id = old.user_id) then return null; end if;
  perform public.audit_add(old.server_id, 'member_kick', 'user', old.user_id, null, '{}'::jsonb);
  return null;
exception when others then return null;
end $$;
create or replace trigger server_members_audit after delete on public.server_members
  for each row execute function public.audit_kicks();

-- Timeouts set, changed, lifted.
create or replace function public.audit_timeouts() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if tg_op = 'DELETE' then
    if old.until > now() then
      perform public.audit_add(old.server_id, 'member_timeout_remove', 'user', old.user_id, null, '{}'::jsonb);
    end if;
  elsif new.until is null or new.until <= now() then
    perform public.audit_add(new.server_id, 'member_timeout_remove', 'user', new.user_id, null, '{}'::jsonb);
  else
    perform public.audit_add(new.server_id, 'member_timeout', 'user', new.user_id, null,
      jsonb_build_object('until', new.until, 'reason', left(coalesce(new.reason, ''), 200)));
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger server_timeouts_audit after insert or delete or update of until on public.server_timeouts
  for each row execute function public.audit_timeouts();

-- Server settings.
create or replace function public.audit_servers() returns trigger language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  d := public.audit_diff(to_jsonb(old), to_jsonb(new), array['name', 'icon_path', 'banner_path', 'description', 'discoverable', 'tag',
    'tickets_on', 'locked_until', 'lock_reason', 'rules_channel_id', 'new_account_minutes', 'new_account_mode', 'everyone_perms', 'theme', 'links', 'tags']);
  -- The raid auto-lock runs inside someone's join: don't pin it on them.
  if coalesce(new.lock_reason, '') like 'auto:%' then
    d := (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(d) x where x ->> 'k' not in ('locked_until', 'lock_reason'));
  end if;
  if jsonb_array_length(d) = 0 then return null; end if;
  -- Pictures and big blobs: only say they changed.
  d := (select jsonb_agg(case when x ->> 'k' in ('icon_path', 'banner_path', 'theme', 'links', 'everyone_perms')
                          then jsonb_build_object('k', x ->> 'k') else x end) from jsonb_array_elements(d) x);
  perform public.audit_add(new.id, 'server_update', 'server', new.id, new.name, jsonb_build_object('changes', d));
  return null;
exception when others then return null;
end $$;
create or replace trigger servers_audit after update of name, icon_path, banner_path, description, discoverable, tag, tickets_on,
  locked_until, lock_reason, rules_channel_id, new_account_minutes, new_account_mode, everyone_perms, theme, links, tags
  on public.servers for each row execute function public.audit_servers();

-- Invites made and removed (not the ones cleared when their maker is kicked, banned or leaves).
create or replace function public.audit_invites() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if tg_op = 'INSERT' then
    perform public.audit_add(new.server_id, 'invite_create', 'invite', null, new.code, jsonb_build_object('vanity', new.vanity));
  else
    if old.created_by <> auth.uid()
       and not exists (select 1 from public.server_members where server_id = old.server_id and user_id = old.created_by) then return null; end if;
    perform public.audit_add(old.server_id, 'invite_delete', 'invite', null, old.code, jsonb_build_object('vanity', old.vanity));
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger invites_audit after insert or delete on public.invites
  for each row execute function public.audit_invites();

-- Bots added and removed.
create or replace function public.audit_bots() returns trigger language plpgsql security definer set search_path = public as $$
declare b uuid := coalesce(new.bot_id, old.bot_id); s uuid := coalesce(new.server_id, old.server_id); bname text;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  select username into bname from public.profiles where id = b;
  perform public.audit_add(s, case when tg_op = 'INSERT' then 'bot_add' else 'bot_remove' end, 'user', b, bname, '{}'::jsonb);
  return null;
exception when others then return null;
end $$;
create or replace trigger bot_servers_audit after insert or delete on public.bot_servers
  for each row execute function public.audit_bots();

-- Webhooks made and removed.
create or replace function public.audit_webhooks() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  if tg_op = 'INSERT' then
    perform public.audit_add(new.server_id, 'webhook_create', 'webhook', new.id, new.name, jsonb_build_object('channel_id', new.channel_id));
  else
    perform public.audit_add(old.server_id, 'webhook_delete', 'webhook', old.id, old.name, jsonb_build_object('channel_id', old.channel_id));
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger webhooks_audit after insert or delete on public.webhooks
  for each row execute function public.audit_webhooks();

-- Channel and category permission overrides.
create or replace function public.audit_overrides() returns trigger language plpgsql security definer set search_path = public as $$
declare r public.channel_overrides; tname text; kind text; rname text;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  r := case when tg_op = 'DELETE' then old else new end;
  if r.channel_id is not null then
    kind := 'channel'; select name into tname from public.channels where id = r.channel_id;
  else
    kind := 'category'; select name into tname from public.channel_categories where id = r.category_id;
  end if;
  if tname is null then return null; end if;
  select name into rname from public.roles where id = r.role_id;
  -- The role was deleted and took its overrides with it.
  if r.role_id is not null and rname is null then return null; end if;
  perform public.audit_add(r.server_id, 'channel_perms', kind, coalesce(r.channel_id, r.category_id), tname,
    jsonb_build_object('role', coalesce(rname, '@everyone'), 'op', lower(tg_op),
      'allow', coalesce(to_jsonb(r.allow), '[]'::jsonb), 'deny', coalesce(to_jsonb(r.deny), '[]'::jsonb)));
  return null;
exception when others then return null;
end $$;
create or replace trigger channel_overrides_audit after insert or delete or update of allow, deny on public.channel_overrides
  for each row execute function public.audit_overrides();

-- Read it. Newest first, 50 at a time; `before` is the last id you have. Optional filters.
create or replace function public.server_audit_list(sid uuid, before bigint default null, act text default null, who uuid default null, lim int default 50)
returns table (id bigint, actor_id uuid, action text, target_kind text, target_id uuid, target_name text, extra jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.feature_on('audit_log', sid) then raise exception 'The audit log isn''t on here yet'; end if;
  if not (public.server_perm(sid, 'view_audit_log') or public.server_perm(sid, 'manage_server')) then
    raise exception 'You can''t see the audit log here';
  end if;
  return query
    select a.id, a.actor_id, a.action, a.target_kind, a.target_id, a.target_name, a.extra, a.created_at
    from public.server_audit_log a
    where a.server_id = sid
      and (before is null or a.id < before)
      and (act is null or a.action like act || '%')
      and (who is null or a.actor_id = who)
    order by a.id desc
    limit least(greatest(coalesce(lim, 50), 1), 100);
end $$;
revoke execute on function public.server_audit_list(uuid, bigint, text, uuid, int) from public, anon;
grant execute on function public.server_audit_list(uuid, bigint, text, uuid, int) to authenticated;

-- 90 days. Daily at 04:20.
create or replace function public.audit_cleanup() returns void language plpgsql security definer set search_path = public as $$
begin
  execute 'del' || 'ete from public.server_audit_log where created_at < now() - interval ''90 days''';
end $$;
revoke execute on function public.audit_cleanup() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'server-audit-cleanup') then
    perform cron.schedule('server-audit-cleanup', '20 4 * * *', 'select public.audit_cleanup()');
  end if;
end $$;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('audit_log', 'Audit log', 'Server Settings > Audit Log: who changed channels, roles, members, invites, bots and settings.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
