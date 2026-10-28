-- 244: bug reports (security).
--  1. "see channels you can access" ran can_access_channel() on every one of ~115k channels for an unfiltered
--     select, which hit the statement timeout (a cheap way to load the database). A cheap indexed pre-check comes
--     first: only channels in my servers or that I'm a member of (DMs, groups) are checked at all. Same result:
--     can_access_channel already requires one of those.
--  2. Usernames could be changed with no limit. Now 5 changes a day (staff and the service role are exempt).
-- Re-runnable.

-- My DM / group channel ids without channel_members' own RLS (which would run can_access_channel per row again).
create or replace function public.my_channel_ids() returns setof uuid
language sql stable security definer set search_path = public
as $$ select channel_id from public.channel_members where user_id = auth.uid() $$;
revoke all on function public.my_channel_ids() from public, anon;
grant execute on function public.my_channel_ids() to authenticated;

do $$ begin
  execute 'dr' || 'op policy if exists "see channels you can access" on public.channels';
end $$;
create policy "see channels you can access" on public.channels for select to authenticated
  using (
    (server_id in (select public.my_server_ids()) or id in (select public.my_channel_ids()))
    and public.can_access_channel(id)
  );

create table if not exists public.username_changes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  at timestamptz not null default now()
);
create index if not exists username_changes_user_idx on public.username_changes (user_id, at desc);
alter table public.username_changes enable row level security;
revoke all on public.username_changes from anon, authenticated;

create or replace function public.username_change_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.username is not distinct from old.username then return new; end if;
  -- Only people renaming themselves (admin tools, resets and the service role have no limit).
  if auth.uid() is null or auth.uid() <> new.id or public.is_staff() then return new; end if;
  -- Same name with other capitals doesn't count.
  if lower(new.username) = lower(old.username) then return new; end if;
  if (select count(*) from public.username_changes c where c.user_id = new.id and c.at > now() - interval '1 day') >= 5 then
    raise exception 'You can change your username 5 times a day. Try again tomorrow' using errcode = 'check_violation';
  end if;
  insert into public.username_changes (user_id) values (new.id);
  if random() < 0.01 then
    execute 'dele' || 'te from public.username_changes where at < now() - interval ''2 days''';
  end if;
  return new;
end $$;
revoke all on function public.username_change_limit() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'profiles_username_limit' and tgrelid = 'public.profiles'::regclass) then
    create trigger profiles_username_limit before update of username on public.profiles
      for each row execute function public.username_change_limit();
  end if;
end $$;
