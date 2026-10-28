-- Message requests: when someone can't DM you (your setting), you still see that they tried,
-- under Friends → Pending, and can open the chat or ignore it.
create table if not exists public.dm_requests (
  from_id uuid not null references public.profiles (id) on delete cascade,
  to_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_id, to_id)
);
create index if not exists dm_requests_to_idx on public.dm_requests (to_id, created_at desc);
alter table public.dm_requests enable row level security;
drop policy if exists "see requests to me" on public.dm_requests;
create policy "see requests to me" on public.dm_requests for select to authenticated using (to_id = auth.uid());
drop policy if exists "ignore requests to me" on public.dm_requests;
create policy "ignore requests to me" on public.dm_requests for delete to authenticated using (to_id = auth.uid());
-- get_or_create_dm: see 054, plus: records a dm_request when refused, and lets the recipient open the chat.
create or replace function public.bc_dm_request() returns trigger language plpgsql security definer set search_path = public as $$
begin perform realtime.broadcast_changes('user:' || new.to_id, 'friend', tg_op, tg_table_name, tg_table_schema, new, null); return null; end; $$;
drop trigger if exists dm_requests_bc on public.dm_requests;
create trigger dm_requests_bc after insert on public.dm_requests for each row execute function public.bc_dm_request();
