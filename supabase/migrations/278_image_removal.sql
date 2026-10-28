set lock_timeout = '3s';
-- 278: legal fixes (flag legal_fixes, test only) after the Oct 19 policy review.
--  Intimate image removal (US TAKE IT DOWN Act): anyone, with or without an account, can ask us to remove an
--  intimate image or video of them shared without consent (real or AI-made). We have 48 hours from a valid request.
--  Requests come in through /api/remove-image (service role only, no direct table access), staff see them in
--  Mod Center with the deadline, and mark them removed / need more info / rejected. The image itself is never
--  uploaded here: people send links to where it is.
-- Re-runnable.

create table if not exists public.image_removal_requests (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  due_at timestamptz not null default now() + interval '48 hours',
  reporter_id uuid references public.profiles (id) on delete set null,
  name text not null check (length(name) between 1 and 200),
  email text not null check (length(email) between 3 and 320),
  for_whom text not null check (for_whom in ('me', 'someone')),
  links text[] not null check (cardinality(links) between 1 and 20),
  details text not null default '' check (length(details) <= 4000),
  signature text not null check (length(signature) between 1 and 200),
  good_faith boolean not null check (good_faith),
  ip_hash text,
  status text not null default 'open' check (status in ('open', 'removed', 'need_info', 'rejected')),
  staff_note text not null default '' check (length(staff_note) <= 1000),
  handled_by uuid references public.profiles (id) on delete set null,
  handled_at timestamptz
);
create index if not exists image_removal_open_idx on public.image_removal_requests (due_at) where status = 'open';
create index if not exists image_removal_ip_idx on public.image_removal_requests (ip_hash, created_at desc);
alter table public.image_removal_requests enable row level security;
revoke all on public.image_removal_requests from anon, authenticated;

-- Staff queue: open ones first, soonest deadline first.
create or replace function public.staff_image_removals(st text default 'open')
returns setof public.image_removal_requests
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query
    select * from public.image_removal_requests r
    where (st = 'open' and r.status in ('open', 'need_info')) or (st <> 'open' and r.status in ('removed', 'rejected'))
    order by case when st = 'open' then extract(epoch from r.due_at) else -extract(epoch from r.handled_at) end
    limit 200;
end $$;
revoke all on function public.staff_image_removals(text) from public, anon;
grant execute on function public.staff_image_removals(text) to authenticated;

create or replace function public.staff_handle_image_removal(rid uuid, st text, note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare who uuid;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if st not in ('removed', 'need_info', 'rejected') then raise exception 'Bad status'; end if;
  if st <> 'removed' and length(btrim(coalesce(note, ''))) < 3 then raise exception 'Say why (the person gets this by email)'; end if;
  update public.image_removal_requests
     set status = st, staff_note = left(btrim(coalesce(note, '')), 1000), handled_by = auth.uid(), handled_at = now()
   where id = rid
  returning reporter_id into who;
  if not found then raise exception 'Request not found'; end if;
  -- target_id is a profile (the requester when signed in); the request id goes in the reason.
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'image_removal_' || st, who, left(rid::text || ' ' || coalesce(note, ''), 120));
end $$;
revoke all on function public.staff_handle_image_removal(uuid, text, text) from public, anon;
grant execute on function public.staff_handle_image_removal(uuid, text, text) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('legal_fixes', 'Legal fixes (Oct 19)', 'Settings, Subscriptions (cancel online), renewal terms by buy buttons, voice clip notice and indicator, intimate image removal form.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
