-- ============================================================
-- Yapper · Delete your own account (GDPR "right to erasure")
-- Removes the login and, through the existing cascades, the profile,
-- messages, reactions, friendships, memberships, custom emojis and any
-- servers the person owns. Uploaded files are removed by the app first.
-- ============================================================

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'You need to be logged in';
  end if;
  -- Deleting the community server everyone joins would take it down for all.
  if exists (
    select 1 from public.app_settings a
    join public.servers s on s.id = a.default_server_id
    where s.owner_id = uid
  ) then
    raise exception 'You own the community server everyone joins, so this account can''t be deleted from the app';
  end if;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
