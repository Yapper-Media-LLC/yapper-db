-- 224: pin DMs (flag `pin_dms`). Pinned DMs and group DMs stay at the top of the Direct Messages list.
--
-- One row per account with the pinned channel ids, newest pin first. Only the owner can read or write it.
-- The app reads it with one primary-key lookup when the DM list mounts (flagged users only), never from bootstrap.
-- The ids are only used to sort the person's own list, so a stale or foreign id does nothing (the app drops ids
-- that aren't in its channel list); the table only caps the size.
-- Re-runnable.

set lock_timeout = '5s';

create table if not exists public.user_dm_pins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  pins uuid[] not null default '{}',
  updated_at timestamptz not null default now(),
  constraint user_dm_pins_max check (cardinality(pins) <= 50 and array_ndims(pins) is distinct from 2 and array_position(pins, null) is null)
);

alter table public.user_dm_pins enable row level security;
revoke all on public.user_dm_pins from public, anon, authenticated;
grant select, insert, update on public.user_dm_pins to authenticated;

-- Read your own row; write it only while the feature is on for you (test users first).
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_dm_pins' and policyname = 'own dm pins read') then
    create policy "own dm pins read" on public.user_dm_pins for select to authenticated
      using ((select auth.uid()) = user_id);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_dm_pins' and policyname = 'own dm pins insert') then
    create policy "own dm pins insert" on public.user_dm_pins for insert to authenticated
      with check ((select auth.uid()) = user_id and (select public.feature_on_for_me('pin_dms')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_dm_pins' and policyname = 'own dm pins update') then
    create policy "own dm pins update" on public.user_dm_pins for update to authenticated
      using ((select auth.uid()) = user_id)
      with check ((select auth.uid()) = user_id and (select public.feature_on_for_me('pin_dms')));
  end if;
end $$;

-- updated_at is the server's clock, whatever the client sends.
create or replace function public.user_dm_pins_touch()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end; $$;
revoke all on function public.user_dm_pins_touch() from public, anon, authenticated;
create or replace trigger user_dm_pins_touch before insert or update on public.user_dm_pins
  for each row execute function public.user_dm_pins_touch();

-- Flag (test only until Antic says publish): Antic's test server and Antic.
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('pin_dms', 'Pin DMs', 'Pin DMs and group chats to the top of your Direct Messages list, synced to your account', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
