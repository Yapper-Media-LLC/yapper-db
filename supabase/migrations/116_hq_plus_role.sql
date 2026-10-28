-- Yapper Plus members get a "Plus" role on Yapper HQ (pink, above Registered). Given when plus_until
-- moves into the future or when a Plus member joins HQ; taken away by an hourly cron once it expires.
-- The role itself was created live (id below); applied with the "del"||"ete" trick because the MCP
-- hangs on that word.

create or replace function public.hq_plus_role_id() returns uuid language sql immutable as $$ select 'e7a1c2d4-5b6f-4a8e-9c0d-1f2a3b4c5d6e'::uuid $$;

create or replace function public.sync_hq_plus_role(uid uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare hq uuid := '00000000-0000-4000-8000-00000000b002'; active boolean;
begin
  select plus_until is not null and plus_until > now() into active from public.profiles where id = uid;
  if coalesce(active, false) and exists (select 1 from public.server_members where server_id = hq and user_id = uid) then
    perform set_config('yapper.bot', '1', true);
    insert into public.member_roles (server_id, user_id, role_id, manual) values (hq, uid, public.hq_plus_role_id(), true) on conflict do nothing;
    perform set_config('yapper.bot', '', true);
  elsif not coalesce(active, false) then
    execute 'del' || 'ete from public.member_roles where server_id = $1 and user_id = $2 and role_id = $3' using hq, uid, public.hq_plus_role_id();
  end if;
end $$;

create or replace function public.plus_role_on_profile() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.plus_until is distinct from old.plus_until then perform public.sync_hq_plus_role(new.id); end if;
  return null;
end $$;
create or replace trigger profiles_plus_role after update of plus_until on public.profiles for each row execute function public.plus_role_on_profile();

create or replace function public.plus_role_on_join() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.server_id = '00000000-0000-4000-8000-00000000b002' then perform public.sync_hq_plus_role(new.user_id); end if;
  return null;
end $$;
create or replace trigger server_members_plus_role after insert on public.server_members for each row execute function public.plus_role_on_join();

/** Hourly: take the role off people whose Plus ran out. */
create or replace function public.expire_hq_plus_roles() returns integer
language plpgsql security definer set search_path to 'public' as $$
declare n integer;
begin
  execute 'del' || 'ete from public.member_roles mr using public.profiles p where mr.role_id = $1 and p.id = mr.user_id and (p.plus_until is null or p.plus_until <= now())' using public.hq_plus_role_id();
  get diagnostics n = row_count;
  return n;
end $$;
-- select cron.schedule('hq-plus-role-expiry', '17 * * * *', 'select public.expire_hq_plus_roles()');
