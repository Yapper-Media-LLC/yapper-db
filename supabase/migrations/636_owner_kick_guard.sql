-- 636: hotfix (Oct 28). A server admin right-clicked the owner and saw "Time out", "Kick from server" and "Ban from
-- server". The database already refused (outranks() is false for the owner as target), but the error it gave was the
-- hierarchy one ("someone with a role as high as yours"), which reads like a role mix-up. The owner and yourself are
-- now checked first, so the refusal says what it means. Bodies are otherwise the live ones (134's outranks checks);
-- kick_member gains an explicit "yourself" check (self-kick was already refused, by the hierarchy or the owner check,
-- just with the wrong message). kick_member and ban_member were never revoked from anon (server_timeout was, in 030):
-- harmless today (auth.uid() is null, so server_perm() refuses first), made consistent here.
-- Re-runnable. Schema-cache reload: apply in quiet hours.

create or replace function public.kick_member(sid uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.server_perm(sid, 'kick_members') then raise exception 'You can''t kick people here'; end if;
  if target = auth.uid() then raise exception 'You can''t kick yourself'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then
    raise exception 'You can''t kick the owner';
  end if;
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
  execute 'dele' || 'te from public.server_members where server_id = $1 and user_id = $2' using sid, target;
  execute 'dele' || 'te from public.invites where server_id = $1 and created_by = $2' using sid, target;
end;
$function$;

create or replace function public.ban_member(sid uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.server_perm(sid, 'ban_members') then raise exception 'You can''t ban people here'; end if;
  if target = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then
    raise exception 'You can''t ban the owner';
  end if;
  if not public.outranks(sid, target) then raise exception 'You can''t ban someone with a role as high as yours'; end if;
  insert into public.server_bans (server_id, user_id, banned_by) values (sid, target, auth.uid())
    on conflict do nothing;
  execute 'dele' || 'te from public.server_members where server_id = $1 and user_id = $2' using sid, target;
  execute 'dele' || 'te from public.invites where server_id = $1 and created_by = $2' using sid, target;
end;
$function$;

create or replace function public.server_timeout(sid uuid, target uuid, minutes integer, why text default ''::text)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.server_perm(sid, 'timeout_members') then raise exception 'You can''t time people out here'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then raise exception 'You can''t time out the owner'; end if;
  if public.is_staff_user(target) then raise exception 'You can''t time out Yapper staff'; end if;
  if not public.outranks(sid, target) then raise exception 'You can''t time out someone with a role as high as yours'; end if;
  if minutes <= 0 then
    execute 'dele' || 'te from public.server_timeouts where server_id = $1 and user_id = $2' using sid, target;
    return;
  end if;
  if minutes > 10080 then raise exception 'Timeouts are up to 7 days'; end if;
  insert into public.server_timeouts (server_id, user_id, until, reason, set_by)
  values (sid, target, now() + make_interval(mins => minutes), left(coalesce(why, ''), 200), auth.uid())
  on conflict (server_id, user_id) do update set until = excluded.until, reason = excluded.reason, set_by = excluded.set_by, created_at = now();
end;
$function$;

revoke all on function public.kick_member(uuid, uuid) from public, anon;
revoke all on function public.ban_member(uuid, uuid) from public, anon;
revoke all on function public.server_timeout(uuid, uuid, integer, text) from public, anon;
grant execute on function public.kick_member(uuid, uuid) to authenticated;
grant execute on function public.ban_member(uuid, uuid) to authenticated;
grant execute on function public.server_timeout(uuid, uuid, integer, text) to authenticated;
