-- Feature flags can also target specific people (e.g. just the admin) in test mode.
alter table public.feature_flags add column if not exists users uuid[] not null default '{}';
create or replace function public.feature_on_for_me(k text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (auth.uid() = any(users) or exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers)))) from public.feature_flags where key = k), false);
$$;
create or replace function public.feature_on(k text, sid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false);
$$;
