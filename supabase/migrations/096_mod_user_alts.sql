-- Mod Center → user file: other accounts that signed in from the same network (applied live Oct 15).
-- Networks shared by more than 60 accounts (mobile carriers, big schools) are skipped: not a signal.
-- For scale: the typical network has 1 account, 95% have 5 or fewer, an alt farm has 30+.
create or replace function public.mod_user_alts(uid uuid)
 returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select case when public.is_staff() then coalesce((
    with mine as (
      select distinct la.ip from public.login_attempts la
      join public.profiles p on p.id = uid and lower(la.username) = lower(p.username)
      where la.ok and la.at > now() - interval '30 days'
    ), shared as (
      select la.ip from public.login_attempts la where la.ip in (select ip from mine) and la.ok and la.at > now() - interval '30 days'
      group by la.ip having count(distinct lower(la.username)) <= 60
    )
    select jsonb_agg(jsonb_build_object('id', p.id, 'username', p.username, 'ips', x.ips, 'banned', exists (select 1 from public.site_bans b where b.user_id = p.id and (b.expires_at is null or b.expires_at > now()))) order by x.ips desc, p.username)
    from (
      select lower(la.username) as uname, count(distinct la.ip) as ips from public.login_attempts la
      where la.ip in (select ip from shared) and la.ok and la.at > now() - interval '30 days'
      group by lower(la.username)
    ) x join public.profiles p on lower(p.username) = x.uname
    where p.id <> uid
  ), '[]'::jsonb) else '[]'::jsonb end;
$function$;
revoke all on function public.mod_user_alts(uuid) from public, anon;
grant execute on function public.mod_user_alts(uuid) to authenticated;
