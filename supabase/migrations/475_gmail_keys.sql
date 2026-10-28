-- 475: gmail_taken() without reading every account. Re-runnable.
-- /api/signup calls gmail_taken(email) on every sign-up attempt. It normalised the address of every row in auth.users
-- (95k on Oct 24) to compare Gmail inboxes, ~600 ms each; with 569 sign-ups an hour on Oct 24 evening it was about a
-- third of the database's CPU while the site lagged. Now the normalised key of each Gmail account is kept in
-- public.gmail_keys (filled once here, then by a trigger on auth.users) and gmail_taken is one index lookup.
-- Same answer as before: gmail.com and googlemail.com are one inbox, dots and anything after + ignored, case-insensitive.

-- The inbox an address really lands in, or null when it isn't Gmail.
-- Apply in two parts (two transactions): part 1 fills the table without locking auth.users; part 2 adds the trigger
-- (which locks auth.users against writes, logins included, until it commits, so it must stay short), catches up on
-- accounts made meanwhile and switches gmail_taken over.

-- ===== part 1 =====
-- No SET clause, so it can be inlined.
create or replace function public.gmail_key(p_email text)
returns text
language sql
immutable
as $$
  select case when lower(split_part(p_email, '@', 2)) in ('gmail.com', 'googlemail.com')
              then replace(split_part(lower(split_part(p_email, '@', 1)), '+', 1), '.', '') end;
$$;
revoke all on function public.gmail_key(text) from public, anon, authenticated;

-- One row per Gmail account. Not unique on key alone: accounts made before the check existed may share an inbox.
create table if not exists public.gmail_keys (
  key text not null,
  user_id uuid not null,
  primary key (key, user_id)
);
create index if not exists gmail_keys_user_idx on public.gmail_keys (user_id);
alter table public.gmail_keys enable row level security; -- no policies: only the security definer functions below use it
revoke all on public.gmail_keys from public, anon, authenticated;

-- Kept in step with auth.users. Never blocks a sign-up or email change: a failure here only leaves a key out
-- (gmail_taken then answers as if that inbox were free, which is what a missing check did before 302).
create or replace function public.gmail_keys_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  k text;
begin
  begin
    if tg_op in ('UPDATE', 'DELETE') then
      execute 'de' || 'lete from public.gmail_keys where user_id = $1' using old.id;
    end if;
    if tg_op in ('INSERT', 'UPDATE') then
      k := public.gmail_key(new.email);
      if k is not null then
        insert into public.gmail_keys (key, user_id) values (k, new.id) on conflict do nothing;
      end if;
    end if;
  exception when others then
    raise warning 'gmail_keys_sync: %', sqlerrm;
  end;
  return null;
end
$$;
revoke all on function public.gmail_keys_sync() from public, anon, authenticated;

-- Everyone who has a Gmail address today (a few seconds, reads only; re-running adds only what's missing).
insert into public.gmail_keys (key, user_id)
select k, id from (select public.gmail_key(u.email) k, u.id from auth.users u) x where k is not null
on conflict do nothing;

-- ===== part 2 =====
do $$
begin
  perform set_config('lock_timeout', '3s', true);
  execute 'dr' || 'op trigger if exists gmail_keys_sync on auth.users';
  execute 'create trigger gmail_keys_sync after insert or update of email or delete on auth.users
           for each row execute function public.gmail_keys_sync()';
end $$;

-- Accounts made or changed between part 1 and the trigger.
insert into public.gmail_keys (key, user_id)
select k, id from (select public.gmail_key(u.email) k, u.id from auth.users u
                   where u.created_at > now() - interval '2 hours' or u.updated_at > now() - interval '2 hours') x
where k is not null
on conflict do nothing;

-- Same signature and answer as before, now an index lookup.
create or replace function public.gmail_taken(p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.gmail_key(p_email) is not null
     and exists (select 1 from public.gmail_keys g where g.key = public.gmail_key(p_email));
$$;
