-- 534: 2x Shards for 48 hours to celebrate 100K users. Antic, Oct 26: "make it so in the next 48 hrs ppl get 2x
-- shards to celebrate 100k users, and also in the shard dashboard make a badge that says that".
-- * shard_event(): the event while it runs (mult, label, ends_at), null otherwise. The window is fixed here, so it
--   ends by itself on 28 Oct 11:00 UTC; nothing to switch off afterwards.
-- * shard_boost(): 468's Plus check (1.5) times the event (2), so 2x for everyone and 3x with Plus. Everything earned
--   goes through shard_earn -> shard_boost (daily, chatting, streaks, invites, quests); purchases, sales and staff
--   changes use shard_post and stay as they are. plpgsql now (sql helpers get re-planned every call on PG17).
--   Execute stays revoked from clients (create or replace keeps 468's grants).
-- * my_shards(): live text plus 'event', for the badge on the Shards page.
-- Re-runnable.

create or replace function public.shard_event()
returns jsonb language plpgsql stable set search_path = public as $$
begin
  if now() >= timestamptz '2026-10-26 10:00:00+00' and now() < timestamptz '2026-10-28 11:00:00+00' then
    return jsonb_build_object('mult', 2, 'label', '100K users', 'ends_at', '2026-10-28T11:00:00Z');
  end if;
  return null;
end; $$;

create or replace function public.shard_boost(uid uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare plus numeric := 1;
begin
  if exists (select 1 from public.profiles p where p.id = uid and p.plus_until > now())
    and exists (select 1 from public.feature_flags f where f.key = 'shard_quests'
                and (f.mode = 'everyone' or (f.mode = 'test' and (uid = any(f.users)
                     or exists (select 1 from public.server_members m where m.user_id = uid and m.server_id = any(f.servers))))))
  then plus := 1.5; end if;
  return plus * coalesce((public.shard_event()->>'mult')::numeric, 1);
end; $$;

create or replace function public.my_shards()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'balance', coalesce(w.balance, 0),
    'earned', coalesce(w.earned_total, 0),
    'streak', case when w.last_day >= (now() at time zone 'utc')::date - 1 then coalesce(w.streak, 0) else 0 end,
    'frozen', coalesce(w.frozen, false) or public.is_site_banned(me.id),
    'level', p.account_level,
    'next_cost', case when p.account_level >= 100 then null else public.level_cost(p.account_level + 1) end,
    'today', jsonb_build_object('minutes', coalesce(d.minutes, 0), 'paid', coalesce(d.paid, 0),
                                'daily', w.last_day = (now() at time zone 'utc')::date),
    'invites', jsonb_build_object(
      'pending', (select count(*) from public.referrals r where r.inviter = me.id and r.status = 'pending'),
      'paid', (select count(*) from public.referrals r where r.inviter = me.id and r.status = 'paid')),
    'boost', public.shard_boost(me.id),
    'event', public.shard_event(),
    'config', public.shard_config())
  from (select (select auth.uid()) as id) me
  join public.profiles p on p.id = me.id
  left join public.shard_wallets w on w.user_id = me.id
  left join public.shard_days d on d.user_id = me.id and d.day = (now() at time zone 'utc')::date;
$$;
