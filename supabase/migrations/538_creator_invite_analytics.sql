-- 538: Invite analytics for creators (Antic, Oct 26: "add analytics how many ppl joined from link").
--   creator_link_hits: clicks on yapin.gg/?ref=<code> per code per day (RefCapture calls creator_link_hit once per
--     browser per code per day; anon can call it, it only counts codes that exist, numbers are vanity only).
--   creator_invite_analytics(): the signed-in creator's clicks, sign-ups and counted sign-ups, totals, last 7 days,
--     and a 14-day series for the dashboard chart. Re-runnable.
set lock_timeout = '4s';

create table if not exists public.creator_link_hits (
  code text not null,
  day date not null default current_date,
  n int not null default 0,
  primary key (code, day)
);
alter table public.creator_link_hits enable row level security;
revoke all on public.creator_link_hits from public, anon, authenticated;

create or replace function public.creator_link_hit(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare c text := lower(btrim(coalesce(p_code, '')));
begin
  if c !~ '^[a-z0-9_.]{2,32}$' then return; end if;
  if not exists (select 1 from public.creator_links where code = c) then return; end if;
  insert into public.creator_link_hits (code, day, n) values (c, current_date, 1)
    on conflict (code, day) do update set n = least(public.creator_link_hits.n + 1, 1000000);
end; $$;
revoke all on function public.creator_link_hit(text) from public;
grant execute on function public.creator_link_hit(text) to anon, authenticated;

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
    'refused', (select count(*) from public.creator_referrals where referrer = me and status = 'refused'),
    'days', (select jsonb_agg(jsonb_build_object('day', d.day, 'clicks', coalesce(h.n, 0), 'signups', coalesce(s.n, 0), 'counted', coalesce(k.n, 0)) order by d.day)
      from generate_series(current_date - 13, current_date, interval '1 day') as d(day)
      left join public.creator_link_hits h on h.code = c and h.day = d.day::date
      left join (select created_at::date dd, count(*) n from public.creator_referrals where referrer = me group by 1) s on s.dd = d.day::date
      left join (select confirmed_at::date dd, count(*) n from public.creator_referrals where referrer = me and status = 'counted' group by 1) k on k.dd = d.day::date)
  );
end; $$;
revoke all on function public.creator_invite_analytics() from public, anon;
grant execute on function public.creator_invite_analytics() to authenticated;
create index if not exists creator_referrals_referrer_confirmed_idx on public.creator_referrals (referrer, confirmed_at) where status = 'counted';
reset lock_timeout;
