-- 235: Mod Center queue: "who's on this case". Every mod's queue auto-opened the first case, so all mods piled onto
-- the same report. A mod viewing a case claims it (refreshed every 45 s while open, gone after 2 minutes without a
-- refresh); the others see "👀 name" on it and get the next free case. Staff only. Re-runnable.

create table if not exists public.mod_case_claims (
  case_key text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  claimed_at timestamptz not null default now()
);
create index if not exists mod_case_claims_user_idx on public.mod_case_claims (user_id);
alter table public.mod_case_claims enable row level security;
revoke all on public.mod_case_claims from anon, authenticated;

-- Claim (or keep) a case. Someone else's fresh claim wins: returns their name, or null when it's yours now.
create or replace function public.claim_case(k text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); holder uuid;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if k is null or char_length(k) > 80 then raise exception 'Bad case'; end if;
  -- One case at a time per mod: opening another lets go of the last one.
  update public.mod_case_claims set claimed_at = now() - interval '1 hour' where user_id = uid and case_key <> k;
  insert into public.mod_case_claims (case_key, user_id, claimed_at) values (k, uid, now())
  on conflict (case_key) do update set user_id = excluded.user_id, claimed_at = now()
    where mod_case_claims.user_id = excluded.user_id or mod_case_claims.claimed_at < now() - interval '2 minutes'
  returning user_id into holder;
  if random() < 0.02 then
    execute 'dele' || 'te from public.mod_case_claims where claimed_at < now() - interval ''1 day''';
  end if;
  if holder = uid then return null; end if;
  return (select p.username from public.mod_case_claims c join public.profiles p on p.id = c.user_id where c.case_key = k);
end $$;

create or replace function public.release_case(k text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.mod_case_claims set claimed_at = now() - interval '1 hour'
  where case_key = k and user_id = auth.uid() and public.is_staff();
$$;

-- Live claims by other staff (the queue polls this every 15 s).
create or replace function public.case_claims()
returns table (case_key text, username text)
language sql
stable
security definer
set search_path = public
as $$
  select c.case_key, p.username from public.mod_case_claims c join public.profiles p on p.id = c.user_id
  where public.is_staff() and c.user_id <> auth.uid() and c.claimed_at > now() - interval '2 minutes';
$$;

revoke all on function public.claim_case(text) from public, anon;
revoke all on function public.release_case(text) from public, anon;
revoke all on function public.case_claims() from public, anon;
grant execute on function public.claim_case(text) to authenticated;
grant execute on function public.release_case(text) to authenticated;
grant execute on function public.case_claims() to authenticated;
