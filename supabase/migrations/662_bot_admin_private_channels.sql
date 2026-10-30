-- 662: A bot whose role has Administrator didn't get messages or commands in a private channel unless its role was
-- added to that channel (bug report cc2f27ee). bot_channel_visible's plain branch (no channel overrides) only knew
-- channel members and the channel's roles; the overrides branch (channel_perm_of) already lets the owner and
-- Administrator through. The plain branch now does the same, like it works for people. Live text as of Oct 29 2026
-- with that one line added (md5 of the live body checked). Re-runnable.

set lock_timeout = '3s';

-- Refuse to run over a live edit made after Oct 29 (the body this file was written against, md5 of prosrc).
do $$
declare src text;
begin
  select p.prosrc into src from pg_proc p where p.oid = to_regprocedure('public.bot_channel_visible(uuid,uuid)');
  if src is not null and md5(src) <> '4ef0d38cfe9199a6702f06435272a517' and position('662:' in src) = 0 then
    raise exception '662: bot_channel_visible changed since Oct 29, merge the Administrator line by hand';
  end if;
end $$;

create or replace function public.bot_channel_visible(bid uuid, cid uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.channels c
    where c.id = coalesce((select t.parent_id from public.channels t where t.id = cid), cid) /* 593: */
      and (
        (c.server_id is not null and exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = c.server_id)
          and case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
            then public.channel_perm_of(bid, c.id, 'view_channel',
                   exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid)
                   or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = bid where cr.channel_id = c.id))
            else (not c.private
               or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid)
               or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = bid where cr.channel_id = c.id)
               /* 662: */ or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                                     where mr.server_id = c.server_id and mr.user_id = bid
                                       and coalesce((r.perms ->> 'administrator')::boolean, false)))
          end)
        or (c.server_id is null and exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid))
      )
  );
$function$;

-- Only the definer functions and the bot API (service role) call it; written down here (it was revoked live in 130).
revoke all on function public.bot_channel_visible(uuid, uuid) from public, anon, authenticated;
grant execute on function public.bot_channel_visible(uuid, uuid) to service_role;
