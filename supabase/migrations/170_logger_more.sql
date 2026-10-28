-- 170: Logger bot logs role changes and pins (16 Oct bug reports: someone trusted with Manage Roles could
-- quietly hand out Ban/Kick, and pins left no trace).
--  * roles: created, deleted, renamed, and permission switches turned on/off ("turned on Ban Members").
--  * messages: pinned / unpinned (a trigger that only fires when pinned_at changes, so ordinary edits and
--    new messages pay nothing). Same rules as the message log: private channels only go to a private log
--    channel (channels with live permission overrides count as private, they may hide from some people),
--    Logger+ ignored channels are skipped, bots and bulk jobs are skipped.
-- Re-runnable.

/** "ban_members" -> "Ban Members". */
create or replace function public.log_perm_name(k text)
returns text language sql immutable set search_path = public as $$
  select initcap(replace(k, '_', ' '))
$$;
revoke all on function public.log_perm_name(text) from public, anon;

create or replace function public.logger_role_edits()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); sid uuid := coalesce(new.server_id, old.server_id); txt text; on_list text[]; off_list text[];
  op jsonb; np jsonb;
begin
  if actor is null or current_setting('yapper.bot', true) = '1' or current_setting('yapper.bulk', true) = '1' then return null; end if;
  if public.bot_cfg(sid, 'logger') is null then return null; end if;
  if tg_op = 'INSERT' then
    txt := '🏷️ **' || public.log_name(actor) || '** made the **' || public.log_clean(new.name, 100) || '** role';
  elsif tg_op = 'DELETE' then
    -- The whole server going away deletes its roles too: nothing to log into.
    if not exists (select 1 from public.servers where id = old.server_id) then return null; end if;
    txt := '🏷️ **' || public.log_name(actor) || '** deleted the **' || public.log_clean(old.name, 100) || '** role';
  else
    -- The old Manage Server / Manage Messages switches count as permissions too.
    op := coalesce(old.perms, '{}'::jsonb) || jsonb_build_object('manage_server_legacy', old.manage_server, 'manage_messages_legacy', old.manage_messages);
    np := coalesce(new.perms, '{}'::jsonb) || jsonb_build_object('manage_server_legacy', new.manage_server, 'manage_messages_legacy', new.manage_messages);
    select array_agg(distinct public.log_perm_name(replace(k, '_legacy', ''))) into on_list
      from jsonb_object_keys(np) k where coalesce((np ->> k)::boolean, false) and not coalesce((op ->> k)::boolean, false);
    select array_agg(distinct public.log_perm_name(replace(k, '_legacy', ''))) into off_list
      from jsonb_object_keys(op) k where coalesce((op ->> k)::boolean, false) and not coalesce((np ->> k)::boolean, false);
    if on_list is null and off_list is null and new.name is not distinct from old.name then return null; end if;
    txt := '🛡️ **' || public.log_name(actor) || '** changed the **' || public.log_clean(new.name, 100) || '** role'
      || case when new.name is distinct from old.name then E'\n' || 'Renamed from **' || public.log_clean(old.name, 100) || '**' else '' end
      || case when on_list is not null then E'\n' || 'Turned on: ' || array_to_string(on_list, ', ') else '' end
      || case when off_list is not null then E'\n' || 'Turned off: ' || array_to_string(off_list, ', ') else '' end;
  end if;
  perform public.bot_log_kind('members', sid, txt);
  return null;
exception when others then return null;
end $$;
revoke all on function public.logger_role_edits() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists roles_logger on public.roles'; end $$;
create trigger roles_logger after insert or delete or update of name, perms, manage_server, manage_messages on public.roles
  for each row execute function public.logger_role_edits();

create or replace function public.logger_pins()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; cname text; srcpriv boolean; cfg jsonb; actor uuid := coalesce(new.pinned_by, auth.uid()); txt text;
begin
  if current_setting('yapper.bulk', true) = '1' or current_setting('yapper.bot', true) = '1' then return null; end if;
  select server_id, name, private into sid, cname, srcpriv from public.channels where id = new.channel_id;
  -- Channels with live permission overrides may be hidden from some people (view_channel): treat them like
  -- private ones, so they never land in a log everyone can read.
  srcpriv := coalesce(srcpriv, false) or public.channel_overrides_live(new.channel_id);
  if sid is null then return null; end if;
  cfg := public.bot_cfg(sid, 'logger');
  if cfg is null or (cfg ->> 'channel_id') = new.channel_id::text then return null; end if;
  -- Private (or override-restricted) channels only go to a private log.
  if srcpriv and not coalesce((select private from public.channels where id = nullif(cfg ->> 'channel_id', '')::uuid), false) then return null; end if;
  if jsonb_typeof(cfg -> 'ignore') = 'array' and (cfg -> 'ignore') ? new.channel_id::text and public.server_plus_on(sid) then return null; end if;
  if new.pinned_at is not null then
    txt := '📌 **' || public.log_name(actor) || '** pinned a message by **' || public.log_name(new.author_id) || '** in **#' || cname || '**';
  else
    txt := '📌 ' || case when auth.uid() is not null then '**' || public.log_name(auth.uid()) || '** unpinned' else 'Unpinned' end
      || ' a message by **' || public.log_name(new.author_id) || '** in **#' || cname || '**';
  end if;
  if coalesce(new.content, '') <> '' then txt := txt || E'\n' || public.log_clean(new.content, 300); end if;
  perform public.bot_log(sid, txt);
  return null;
exception when others then return null;
end $$;
revoke all on function public.logger_pins() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists messages_logger_pins on public.messages'; end $$;
create trigger messages_logger_pins after update of pinned_at on public.messages
  for each row when (old.pinned_at is distinct from new.pinned_at)
  execute function public.logger_pins();
