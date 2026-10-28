-- 611: Plus tenure badges (flag plus_tenure_badges, test). profiles.plus_since = when the current Plus streak began,
-- so the PLUS pill can show a 1 / 3 / 6 month, 1 / 2 / 3 / 5 year badge and "Subscriber since ...".
-- Set by a trigger whenever plus_until moves, so every way Plus is given counts (Stripe, gifts, giveaways,
-- creator rewards, Mod Center). The streak survives a gap of up to 7 days (failed card retries); a longer gap restarts it.
-- Readable by everyone like plus_until; nobody can write it (profiles has no table-level update grant).

set lock_timeout = '3s';
alter table public.profiles add column if not exists plus_since timestamptz;
reset lock_timeout;
grant select (plus_since) on public.profiles to anon, authenticated;

create or replace function public.plus_since_on_profile() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.plus_until is distinct from old.plus_until and new.plus_until > now()
     and (old.plus_since is null or old.plus_until is null or old.plus_until < now() - interval '7 days') then
    new.plus_since := now();
  end if;
  return new;
end $$;
revoke all on function public.plus_since_on_profile() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists profiles_plus_since on public.profiles'; end $$;
create trigger profiles_plus_since before update of plus_until on public.profiles
  for each row execute function public.plus_since_on_profile();

-- Backfill current subscribers: their first paid Plus event or first gift, whichever came first, else now.
-- Every recorded sale is from Oct 13, 2026 on and Plus comes in 31 day blocks, so nobody has a gap to skip yet.
update public.profiles p set plus_since = coalesce(
    least((select min(e.created_at) from public.plus_events e
            where e.user_id = p.id and e.state = 'done' and e.note is null and e.kind in ('checkout.session.completed', 'invoice.paid')),
          (select min(g.created_at) from public.plus_gifts g where g.recipient_id = p.id)),
    now())
 where p.plus_until > now() and p.plus_since is null;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('plus_tenure_badges', 'Plus tenure badges', 'The PLUS pill gets a new badge at 1, 3 and 6 months and 1, 2, 3 and 5 years of Plus in a row, with "Subscriber since" on hover.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
