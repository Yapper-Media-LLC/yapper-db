-- 500: channel visibility without per-channel security-definer calls (same rows, ~8-10x faster). Re-runnable.
-- DDL: apply before 14:00 UTC (both PostgRESTs reload their schema cache).
--
-- Why (Oct 25): visible_server_channels_fast (inside bootstrap_fast and unread_counts_v2) and visible_server_channels
-- (loadChannels / resync) called channel_perm_of(.., channel_view_base(..)) and server_perm once per channel. On
-- Postgres 17 a language-sql security-definer function is planned again on every call (~0.5-1.7 ms each), so a user
-- in many servers paid seconds: unread_counts_v2 was 45k s and visible_server_channels 20k s of ~230k s of database
-- time in 15 h. Now the per-server answers (manage_server, owner/administrator) are worked out once per server and the
-- channel_perm_of / channel_view_base rules are written out as one set lookup per channel.
-- Checked against the old functions (md5 of every returned row, repeatable read): 0 mismatches for 59 tricky users
-- (top members, all 18 staff, owners of servers with overrides, holders of override roles) and 80 random active ones;
-- heaviest user 2,041 -> 216 ms, random users 28.5 -> 3.8 ms on average.
-- Keep in step: this copies the view_channel logic of channel_perm_of, channel_view_base and auto_role_applies.
-- A change to those must be mirrored here (check it the same way: old vs new rows for real users, rolled back).

create or replace function public.visible_server_channels_fast(sids uuid[])
returns setof public.channels
language plpgsql stable security definer
set search_path to 'public'
as $function$
begin
  return query
  with me as materialized (select auth.uid() as uid, public.is_staff() as staff),
  mine as materialized (
    select sm.server_id, sm.joined_at,
           exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and sm.server_id = any(f.servers)))) as cp
    from public.server_members sm, me
    where sm.user_id = me.uid and (sids is null or sm.server_id = any(sids))
  ),
  ch as materialized (
    -- lateral + offset 0: one channels_server_idx probe per server (the old merge join walked ~160k channels)
    select l.c, mine.server_id, mine.joined_at,
           mine.cp and exists (select 1 from public.channel_overrides o where o.channel_id = (l.c).id or o.category_id = (l.c).category_id) as ovr
    from mine cross join lateral (select c from public.channels c where c.server_id = mine.server_id offset 0) l
  ),
  -- Once per server instead of once per channel: manage_server, and channel_perm_of's owner/administrator shortcut.
  srv as materialized (
    select x.server_id,
           case when x.need_mg then public.server_perm(x.server_id, 'manage_server') else false end as mg,
           x.any_ovr and (
             exists (select 1 from public.servers s where s.id = x.server_id and s.owner_id = (select uid from me))
             or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                        where mr.server_id = x.server_id and mr.user_id = (select uid from me)
                          and coalesce((r.perms->>'administrator')::boolean, false))) as adm
    from (select ch.server_id, bool_or(coalesce((ch.c).private, false) or ch.ovr) as need_mg, bool_or(ch.ovr) as any_ovr
          from ch group by ch.server_id) x
  )
  select (ch.c).*
  from ch
  join srv on srv.server_id = ch.server_id
  cross join me
  left join lateral (
    -- channel_perm_of(me, c, 'view_channel', base) inlined: same eight flags, only for channels with overrides.
    select coalesce(bool_or(o.category_id is not null and o.role_id is null and 'view_channel' = any(o.allow)), false) as ce_a,
           coalesce(bool_or(o.category_id is not null and o.role_id is null and 'view_channel' = any(o.deny)), false) as ce_d,
           coalesce(bool_or(o.category_id is not null and o.role_id is not null and 'view_channel' = any(o.allow)), false) as cr_a,
           coalesce(bool_or(o.category_id is not null and o.role_id is not null and 'view_channel' = any(o.deny)), false) as cr_d,
           coalesce(bool_or(o.channel_id is not null and o.role_id is null and 'view_channel' = any(o.allow)), false) as he_a,
           coalesce(bool_or(o.channel_id is not null and o.role_id is null and 'view_channel' = any(o.deny)), false) as he_d,
           coalesce(bool_or(o.channel_id is not null and o.role_id is not null and 'view_channel' = any(o.allow)), false) as hr_a,
           coalesce(bool_or(o.channel_id is not null and o.role_id is not null and 'view_channel' = any(o.deny)), false) as hr_d
    from public.channel_overrides o
    where ch.ovr and not srv.adm
      and (o.channel_id = (ch.c).id or ((ch.c).category_id is not null and o.category_id = (ch.c).category_id))
      and (o.role_id is null
           or o.role_id in (select mr.role_id from public.member_roles mr where mr.server_id = ch.server_id and mr.user_id = me.uid)
           or exists (select 1 from public.roles r join public.server_members sm on sm.server_id = r.server_id and sm.user_id = me.uid
                      where r.id = o.role_id
                        and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and sm.joined_at < r.auto_before))))
  ) ov on true
  where case when ch.ovr then
      exists (select 1 from public.channel_members cm where cm.channel_id = (ch.c).id and cm.user_id = me.uid)
      or srv.adm
      or case
           when ov.hr_a then true
           -- channel_view_base(c), only asked when no role override already allowed it
           when srv.mg
             or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = me.uid where cr.channel_id = (ch.c).id)
             or exists (select 1 from public.channel_roles cr join public.roles r on r.id = cr.role_id
                        join public.server_members sm on sm.server_id = r.server_id and sm.user_id = me.uid
                        where cr.channel_id = (ch.c).id
                          and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and sm.joined_at < r.auto_before)))
             or (me.staff and (ch.c).ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = (ch.c).id)
                 and (public.is_site_admin() or public.staff_peek_ok(ch.server_id)))
             then true
           when ov.hr_d then false
           when ov.he_a then true
           when ov.he_d or coalesce((ch.c).private, false) then false
           when ov.cr_a then true
           when ov.cr_d then false
           when ov.ce_a then true
           when ov.ce_d then false
           else true
         end
    else (
      not (ch.c).private
     or srv.mg
     or exists (select 1 from public.channel_members cm where cm.channel_id = (ch.c).id and cm.user_id = me.uid)
     or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = me.uid where cr.channel_id = (ch.c).id)
     or exists (select 1 from public.channel_roles cr join public.roles r on r.id = cr.role_id
                where cr.channel_id = (ch.c).id
                  and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and ch.joined_at < r.auto_before)))
     or (me.staff and (ch.c).ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = (ch.c).id)
         and (public.is_site_admin() or public.staff_peek_ok(ch.server_id)))
    ) end;
end
$function$;


-- Same rules plus the site-ban check (the only difference between the two before).
create or replace function public.visible_server_channels(sids uuid[])
returns setof public.channels
language plpgsql stable security definer
set search_path to 'public'
as $function$
begin
  if public.is_site_banned(auth.uid()) then return; end if;
  return query select * from public.visible_server_channels_fast(sids);
end
$function$;
