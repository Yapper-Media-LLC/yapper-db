-- ============================================================
-- Yapper · Server-level timeouts (applied to production 2026-10-13)
-- Anyone with "manage messages" in a server can time a member out of it
-- (no posting, no voice) for up to 7 days. Kick/ban already existed; they're
-- now reachable by right-clicking a member or a message.
-- ============================================================

create table if not exists public.server_timeouts (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  until timestamptz not null,
  reason text not null default '',
  set_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (server_id, user_id)
);
alter table public.server_timeouts enable row level security;
drop policy if exists "mods and the person see server timeouts" on public.server_timeouts;
create policy "mods and the person see server timeouts" on public.server_timeouts for select to authenticated
  using (user_id = auth.uid() or public.server_perm(server_id, 'manage_messages'));

create or replace function public.server_timeout(sid uuid, target uuid, minutes int, why text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'manage_messages') then raise exception 'You can''t time people out here'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = target) then raise exception 'You can''t time out the owner'; end if;
  if public.is_staff_user(target) then raise exception 'You can''t time out Yapper staff'; end if;
  if minutes <= 0 then
    delete from public.server_timeouts where server_id = sid and user_id = target;
    return;
  end if;
  if minutes > 10080 then raise exception 'Timeouts are up to 7 days'; end if;
  insert into public.server_timeouts (server_id, user_id, until, reason, set_by)
  values (sid, target, now() + make_interval(mins => minutes), left(coalesce(why, ''), 200), auth.uid())
  on conflict (server_id, user_id) do update set until = excluded.until, reason = excluded.reason, set_by = excluded.set_by, created_at = now();
end;
$$;
revoke all on function public.server_timeout(uuid, uuid, int, text) from public, anon;
grant execute on function public.server_timeout(uuid, uuid, int, text) to authenticated;

create or replace function public.server_timed_out(sid uuid, uid uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select until from public.server_timeouts where server_id = sid and user_id = uid and until > now();
$$;

create or replace function public.block_server_timeouts()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; u timestamptz;
begin
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then return new; end if;
  u := public.server_timed_out(sid, new.author_id);
  if u is not null then
    raise exception 'You''re timed out in this server until %.', to_char(u at time zone 'UTC', 'HH24:MI UTC') using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists messages_server_timeout on public.messages;
create trigger messages_server_timeout before insert on public.messages for each row execute function public.block_server_timeouts();
