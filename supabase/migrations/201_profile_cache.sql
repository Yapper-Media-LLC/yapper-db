-- Profile lookups through the realtime server's shared cache (ops/realtime/profileCache.mjs), test servers only for now.
insert into public.feature_flags (key, label, description, mode, servers)
values ('profile_cache', 'Profile cache', 'Profile lookups through the realtime server', 'test', '{}')
on conflict (key) do nothing;

-- Server-side profile changes (Stripe Plus, bot/webhook profiles, image take-downs, email verification) tell the
-- realtime server to forget its cached copy. Goes through public.bc like every other live event (pg_net POST to
-- <rt_url>/publish with the vault secret), so Vercel needs no realtime secret. Topic 'profile:<id>' has no
-- subscribers (the realtime server never lets anyone join it); the server only reads the id and drops that row.
-- Service role only (app/api, lib/server/rtProfile.ts).
create or replace function public.rt_profile_changed(uids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare ping record; nothing record;
begin
  select null::uuid as id into nothing;
  for ping in select distinct u as id from unnest(coalesce(uids, '{}'::uuid[])) u where u is not null limit 200 loop
    perform public.bc('profile:' || ping.id, 'profile', 'UPDATE', 'profiles', 'public', ping, nothing);
  end loop;
end; $$;
revoke execute on function public.rt_profile_changed(uuid[]) from public, anon, authenticated;
grant execute on function public.rt_profile_changed(uuid[]) to service_role;
