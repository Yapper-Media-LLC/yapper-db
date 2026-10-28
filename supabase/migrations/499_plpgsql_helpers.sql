-- 499: permission helpers in plpgsql so their query plans are cached.
--
-- Why: these helpers were `language sql` + SECURITY DEFINER + `set search_path`. That combination
-- can't be inlined, so Postgres (17) parsed and planned the body again on every single call. They run
-- per row inside RLS policies and inside each other, and took ~40k of ~230k seconds of database time
-- in 15 h. A plpgsql body keeps its plans per backend after the first call.
-- Measured per call (uncached sql vs cached): is_server_member 0.83 ms vs 0.08 ms,
-- server_perm 4.1 vs 0.31 ms, can_access_channel 4.5-14 ms vs 0.7 ms.
--
-- Bodies are the live ones word for word, wrapped as `return (<original select>);` (one row, NULL
-- stays NULL), and `return query` for my_server_ids. Same names, args, return types, STABLE,
-- SECURITY DEFINER and search_path, so owner and grants stay as they are (create or replace).
-- `#variable_conflict use_column` keeps the sql rule that a column name wins over a parameter name
-- (no clashes today; it just keeps it that way if a column called cid/sid/uid/... ever shows up).
-- channel_allows, channel_perm and channel_perm_of are plpgsql already and are left alone.
--
-- DDL: apply before 14:00 UTC (both PostgRESTs reload their schema cache). Re-runnable.

create or replace function public.auto_role_applies(rid uuid, uid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select uid is not null and exists (
    select 1 from public.roles r
    join public.server_members sm on sm.server_id = r.server_id and sm.user_id = uid
    where r.id = rid
      and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and sm.joined_at < r.auto_before))
  )
  );
end;
$function$;

create or replace function public.can_access_channel(cid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select
    not public.is_site_banned(auth.uid())
    and (
      public.is_channel_member(cid)
      or exists (
        select 1 from public.channels c
        where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
          and not exists (select 1 from public.servers sd where sd.id = c.server_id and sd.shut_down_at is not null and not public.is_staff())
          and case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                                and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                    and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
            then public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
            else (
              not c.private
              or public.server_perm(c.server_id, 'manage_server')
              or exists (
                select 1 from public.channel_roles cr
                join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
                where cr.channel_id = c.id
              )
              or exists (select 1 from public.channel_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
              or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id) and (public.is_site_admin() or public.staff_peek_ok(c.server_id)))
            ) end
      )
    )
  );
end;
$function$;

create or replace function public.can_post_channel(cid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select coalesce((
    select
      (c.server_id is null
        or case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
             then public.channel_perm(c.id, 'send_messages')
             else public.server_perm(c.server_id, 'send_messages') end)
      and (
        not c.read_only
        or public.server_perm(c.server_id, 'manage_server')
        or exists (
          select 1 from public.channel_post_roles cr
          join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
          where cr.channel_id = c.id
        )
        or exists (select 1 from public.channel_post_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
      )
    from public.channels c where c.id = cid
  ), true)
  );
end;
$function$;

create or replace function public.channel_access_server(cid uuid)
 returns text
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select case when public.can_access_channel(cid) then coalesce((select server_id::text from public.channels where id = cid), 'dm') end
  );
end;
$function$;

create or replace function public.channel_history_ok(cid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select coalesce((select case when c.server_id is null then true
                               when c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id) then false
                               when c.kind = 'voice' and public.channel_overrides_live(c.id) and not public.channel_perm(c.id, 'connect') then false
                               -- Overrides where they are live, else the server-wide permission (owner / Administrator
                               -- always, a role that grants it, or every member unless everyone_perms says no).
                               else public.channel_allows(c.id, 'read_history') end
                   from public.channels c where c.id = cid), true)
  );
end;
$function$;

create or replace function public.channel_overrides_live(cid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select coalesce((
    select exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
       and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
    from public.channels c where c.id = cid), false)
  );
end;
$function$;

create or replace function public.channel_view_base(cid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select exists (
    select 1 from public.channels c
    where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
      and (
        public.server_perm(c.server_id, 'manage_server')
        or exists (
          select 1 from public.channel_roles cr
          join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
          where cr.channel_id = c.id
        )
        or exists (select 1 from public.channel_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
        or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id) and (public.is_site_admin() or public.staff_peek_ok(c.server_id)))
      )
  )
  );
end;
$function$;

create or replace function public.dm_blocked(cid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select exists (
    select 1
    from public.channels c
    join public.channel_members m1 on m1.channel_id = c.id
    join public.channel_members m2 on m2.channel_id = c.id and m2.user_id <> m1.user_id
    where c.id = cid and c.kind = 'dm'
      and public.is_blocked_between(m1.user_id, m2.user_id)
  )
  );
end;
$function$;

create or replace function public.feature_on(k text, sid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false)
  );
end;
$function$;

create or replace function public.is_channel_member(cid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select exists (
    select 1 from public.channel_members
    where channel_id = cid and user_id = auth.uid()
  )
  );
end;
$function$;

create or replace function public.is_server_member(sid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select exists (select 1 from public.server_members where server_id = sid and user_id = auth.uid())
  );
end;
$function$;

create or replace function public.is_site_admin()
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select exists (select 1 from public.site_admins where user_id = auth.uid()) and public.staff_mfa_ok()
  );
end;
$function$;

create or replace function public.is_site_banned(uid uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()))
  );
end;
$function$;

create or replace function public.is_site_mod()
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) and public.staff_mfa_ok()
  );
end;
$function$;

create or replace function public.is_staff()
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select public.is_site_admin() or public.is_site_mod()
  );
end;
$function$;

create or replace function public.my_server_ids()
 returns setof uuid
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return query
  select server_id from public.server_members where user_id = auth.uid();
end;
$function$;

create or replace function public.server_perm(sid uuid, perm text)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  select sid is not null and (
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
    or (public.basic_perm(perm)
        and public.is_server_member(sid)
        and coalesce(((select everyone_perms from public.servers where id = sid)->>perm)::boolean, true))
  )
  );
end;
$function$;

create or replace function public.staff_mfa_ok()
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  return (
  -- Staff 2FA (flag staff_2fa): staff powers need a session that passed the authenticator check (aal2).
  select not public.feature_on('staff_2fa', null) or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
  );
end;
$function$;
