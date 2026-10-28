-- 137: logged-out homepage (flag `homepage`) and its "N people online now" counter.
--
-- online_count(): how many people are online right now. Same rule as the rest of the app: a heartbeat
--   in the last 100 seconds (invisible / logging off sets last_seen back by 100s, so they drop out).
--   Yapper's own bots and developer bots also write presence rows; they are not people, so they don't count.
--   Uses the presence_last_seen index (058). Called through /api/home, which the CDN caches for 30s,
--   so it runs a couple of times a minute, not once per visitor.
-- homepage_on(): true when the `homepage` flag is on for everyone. Logged-out visitors can't read
--   feature_flags (the select policy is for signed-in users only), so this tells them just that one bit.
-- Both are callable by anon and signed-in users and return nothing private.

create index if not exists presence_last_seen on public.presence (last_seen);

create or replace function public.online_count()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from public.presence p
  where p.last_seen > now() - interval '100 seconds'
    and not exists (select 1 from public.bot_accounts b where b.user_id = p.user_id)
    and not exists (select 1 from public.bots d where d.id = p.user_id);
$$;
revoke all on function public.online_count() from public;
grant execute on function public.online_count() to anon, authenticated;

create or replace function public.homepage_on()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select f.mode = 'everyone' from public.feature_flags f where f.key = 'homepage'), false);
$$;
revoke all on function public.homepage_on() from public;
grant execute on function public.homepage_on() to anon, authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('homepage', 'Homepage', 'A real logged-out homepage (hero, live online counter, features) before the log in screen. Preview logged out with ?home=1', 'test', '{}', array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;
