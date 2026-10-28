-- 539: db-security-reviewer notes on 538: creator_link_hit drops concurrent floods on one code (advisory lock, no
-- row-lock pile-up, no dead-tuple storm); creator_invite_analytics stops returning the refused count (a refusal
-- signal tells an alt farmer their latest alt got caught, 518 took that read away on purpose). Re-runnable.
set lock_timeout = '4s';
create or replace function public.creator_link_hit(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare c text := lower(btrim(coalesce(p_code, '')));
begin
  if c !~ '^[a-z0-9_.]{2,32}$' then return; end if;
  if not exists (select 1 from public.creator_links where code = c) then return; end if;
  if not pg_try_advisory_xact_lock(hashtext('creator_link_hit:' || c)) then return; end if;
  insert into public.creator_link_hits (code, day, n) values (c, current_date, 1)
    on conflict (code, day) do update set n = least(public.creator_link_hits.n + 1, 1000000);
end; $$;

create or replace function public.creator_invite_analytics()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); c text;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('creator_program') then raise exception 'Not available yet'; end if;
  if not exists (select 1 from public.profiles where id = me and badges && array['creator_1', 'creator_2', 'creator_3']) then return null; end if;
  select code into c from public.creator_links where user_id = me;
  if c is null then return null; end if;
  return jsonb_build_object(
    'clicks', coalesce((select sum(n) from public.creator_link_hits where code = c), 0),
    'clicks_7d', coalesce((select sum(n) from public.creator_link_hits where code = c and day >= current_date - 6), 0),
    'signups', (select count(*) from public.creator_referrals where referrer = me),
    'signups_7d', (select count(*) from public.creator_referrals where referrer = me and created_at >= current_date - 6),
    'counted', (select count(*) from public.creator_referrals where referrer = me and status = 'counted'),
    'counted_7d', (select count(*) from public.creator_referrals where referrer = me and status = 'counted' and confirmed_at >= current_date - 6),
    'waiting', (select count(*) from public.creator_referrals where referrer = me and status = 'pending'),
    'days', (select jsonb_agg(jsonb_build_object('day', d.day, 'clicks', coalesce(h.n, 0), 'signups', coalesce(s.n, 0), 'counted', coalesce(k.n, 0)) order by d.day)
      from generate_series(current_date - 13, current_date, interval '1 day') as d(day)
      left join public.creator_link_hits h on h.code = c and h.day = d.day::date
      left join (select created_at::date dd, count(*) n from public.creator_referrals where referrer = me group by 1) s on s.dd = d.day::date
      left join (select confirmed_at::date dd, count(*) n from public.creator_referrals where referrer = me and status = 'counted' group by 1) k on k.dd = d.day::date)
  );
end; $$;
reset lock_timeout;
