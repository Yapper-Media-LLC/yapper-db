-- Bots: show as online while they poll, and stop counting towards member counts (bots were being
-- added to farm Discovery rank). In-house bots are always online.

/** Called by the bot API on every event poll (service role): same bookkeeping as heartbeat(). */
create or replace function public.bot_presence(bid uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.presence (user_id, status) values (bid, 'online')
  on conflict (user_id) do update set
    last_seen = now(),
    online_since = case when presence.last_seen < now() - interval '100 seconds' then now() else presence.online_since end,
    status = 'online',
    status_at = case when presence.status is distinct from 'online' then now() else presence.status_at end;
$$;
revoke all on function public.bot_presence(uuid) from public, anon, authenticated;

/** Yapper's own bots (Welcomer, Helper, Levels) are always online. Run by pg_cron every minute. */
create or replace function public.inhouse_bots_online() returns void
language sql security definer set search_path = public as $$
  select public.bot_presence(user_id) from public.bot_accounts;
$$;
-- select cron.schedule('inhouse-bots-online', '* * * * *', 'select public.inhouse_bots_online()');

/** Member counts leave bots out. */
create or replace function public.is_bot_user(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bots b where b.id = uid) or exists (select 1 from public.bot_accounts a where a.user_id = uid);
$$;

create or replace function public.bump_member_count() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'INSERT' then
    if public.is_bot_user(new.user_id) then return null; end if;
    update public.servers set member_count = member_count + 1 where id = new.server_id;
  elsif tg_op = 'DELETE' then
    if public.is_bot_user(old.user_id) then return null; end if;
    update public.servers set member_count = greatest(0, member_count - 1) where id = old.server_id;
  end if;
  return null;
end $$;

-- Backfill, only where a bot is a member (keeps the lock short).
update public.servers s set member_count = c.n
from (
  select m.server_id, count(*) filter (where not public.is_bot_user(m.user_id)) as n
  from public.server_members m
  where m.server_id in (select distinct server_id from public.bot_servers)
  group by m.server_id
) c
where c.server_id = s.id and s.member_count is distinct from c.n;
