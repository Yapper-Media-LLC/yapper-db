-- Mute a whole server: no sounds or pop-ups from it (mention badges still show).
create table if not exists public.server_mutes (
  user_id uuid not null references public.profiles (id) on delete cascade,
  server_id uuid not null references public.servers (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, server_id)
);
alter table public.server_mutes enable row level security;
create policy "own server mutes: read" on public.server_mutes for select to authenticated using (user_id = auth.uid());
create policy "own server mutes: add" on public.server_mutes for insert to authenticated with check (user_id = auth.uid());
create policy "own server mutes: remove" on public.server_mutes for delete to authenticated using (user_id = auth.uid());
