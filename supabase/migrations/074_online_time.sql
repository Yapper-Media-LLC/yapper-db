-- Time online per person per day, credited by heartbeat() (applied live Oct 14). admin_online_leaders(days, lim) ranks it.
create table if not exists public.online_time (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  secs int not null default 0,
  primary key (user_id, day)
);
alter table public.online_time enable row level security;
create policy "admins read online time" on public.online_time for select to authenticated using (public.is_site_admin());
grant select on public.online_time to authenticated;
