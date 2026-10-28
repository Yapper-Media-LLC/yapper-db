-- ============================================================
-- Yapper · Everyone starts in a community server
-- New accounts automatically join the server set in app_settings
-- (Yapper Headquarters on the public site).
-- ============================================================

create table public.app_settings (
  id boolean primary key default true check (id),
  default_server_id uuid references public.servers (id) on delete set null
);
insert into public.app_settings (id) values (true) on conflict do nothing;
-- Only the database itself reads this; no one can see or change it from the app.
alter table public.app_settings enable row level security;

create or replace function public.join_default_server()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid := (select default_server_id from public.app_settings where id);
begin
  if sid is not null then
    insert into public.server_members (server_id, user_id) values (sid, new.id) on conflict do nothing;
  end if;
  return new;
end;
$$;

create trigger profiles_join_default_server
  after insert on public.profiles
  for each row execute function public.join_default_server();
