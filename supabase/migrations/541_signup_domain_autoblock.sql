-- 541: tighter signup domain cap, and farm domains blocked for good (Oct 26). One person made 5 accounts on
-- deezlynuts.online in 25 minutes to grab short usernames: exactly the old cap of 5, so nothing was refused and they
-- could make 5 more the next day.
--   * signup_domain_gate: the cap is 3 new accounts per domain in 24 hours (was 5). A domain with characters no real
--     domain has (%, _, \, spaces...) is refused outright.
--   * Auto-block (flag signup_domain_cap 'everyone'): a domain goes into blocked_email_domains for good once 3 of its
--     accounts have confirmed their email AND it's new (its first account is under 7 days old). Confirming needs the
--     mailbox, so nobody can get someone else's domain blocked with fake sign-ups, and schools, ISPs and companies
--     that have been here a while are never blocked. It runs in a trigger on auth.users and can never make a sign-up
--     or confirmation fail. Each block goes into mod_log ('signup_domain_block'). Accounts already made stay.
--   * signup_domain_seen keeps each domain's first account time and confirmed count (filled from auth.users here),
--     so none of this searches auth.users by email.
--   * block_throwaway_emails compares domains exactly (the domain and the one it's under) instead of LIKE: a % or _
--     in a row was a wildcard, and the LIKE scanned all ~10k rows on every sign-up.
--   * School and town domains that hit the cap so far go into signup_domain_ok (never capped or blocked). Domains
--     whose registered name looks like a school (kentwoodschools.org, osloskolen.no) are never auto-blocked but still
--     capped. A time window can't tell them apart: umea.se and bentonvillek12.org reached 3 confirmed as fast as farms.
-- To undo a block: remove the row from blocked_email_domains and add the domain to signup_domain_ok. Re-runnable.
-- Applied live Oct 26 12:45 UTC under the name 411_signup_domain_autoblock (written on an old branch; 411 was taken).

-- Give up rather than make logins wait if auth.users is busy.
set local lock_timeout = '5s';

-- Big providers, schools and staff-allowlisted domains: never capped, never blocked.
create or replace function public.signup_domain_exempt(dom text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.signup_domain_ok where domain in (dom, public.signup_domain_base(dom)))
      or dom ~ '^(outlook|hotmail|live|yahoo|windowslive)\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$'
      or dom ~ '\.edu$' or dom ~ '\.(edu|ac|sch)\.[a-z]{2}$' or dom ~ '\.k12\.[a-z]{2}\.us$'
      -- 541: US state domains (x.k12.wv.us is counted as wv.us).
      or public.signup_domain_base(dom) ~ '^[a-z]{2}\.us$'
$$;
revoke all on function public.signup_domain_exempt(text) from public, anon, authenticated;
grant execute on function public.signup_domain_exempt(text) to service_role;

-- Looks like a school (k12 districts, skole/skola, leerling...) by its registered name, not on a cheap farm ending.
-- Only spares a domain the auto-block; the daily cap still counts it, so a farm naming itself "school" gets 3 a day.
create or replace function public.signup_domain_schoolish(dom text)
returns boolean
language sql
stable
set search_path = public
as $$
  select split_part(public.signup_domain_base(dom), '.', 1) ~ '(school|schol|skol|k12|academy|college|leerling|student|isd[0-9]|usd[0-9])'
     and public.signup_domain_base(dom) !~ '\.(shop|online|xyz|top|sbs|site|store|fun|icu|click|rip|lol|space|cfd|life|live|pro|lat|cc|im|sh|win|pics|link|buzz|cyou|monster)$'
$$;
revoke all on function public.signup_domain_schoolish(text) from public, anon, authenticated;
grant execute on function public.signup_domain_schoolish(text) to service_role;

-- Letters, digits and hyphens in dot-separated labels, at least two labels.
create or replace function public.signup_domain_valid(dom text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select coalesce(length(dom) <= 253 and dom ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$', false)
$$;
revoke all on function public.signup_domain_valid(text) from public, anon, authenticated;
grant execute on function public.signup_domain_valid(text) to service_role;

create table if not exists public.signup_domain_seen (
  domain text primary key,
  first_seen timestamptz not null default now(),
  confirmed int not null default 0
);
alter table public.signup_domain_seen enable row level security;
revoke all on public.signup_domain_seen from anon, authenticated;

-- Fill (or re-count) from the accounts there are now.
insert into public.signup_domain_seen (domain, first_seen, confirmed)
select d, min(created_at), count(*) filter (where email_confirmed_at is not null)
from (
  select public.signup_domain_base(split_part(lower(email), '@', 2)) d, created_at, email_confirmed_at
  from auth.users where email like '%@%'
) u
where d <> ''
group by d
on conflict (domain) do update set first_seen = least(signup_domain_seen.first_seen, excluded.first_seen),
                                  confirmed = excluded.confirmed;

insert into public.signup_domain_ok (domain, note) values
  ('bentonvillek12.org', 'school district, hit the cap (541)'),
  ('kyschools.us', 'school district, hit the cap (541)'),
  ('ccsd.net', 'school district, hit the cap (541)'),
  ('school.nz', 'NZ schools, hit the cap (541)'),
  ('bradleyschools.org', 'school district, hit the cap (541)'),
  ('wonderfulcollegeprep.org', 'school, hit the cap (541)'),
  ('lund.se', 'town and schools, hit the cap (541)'),
  ('sjobo.se', 'town and schools, hit the cap (541)'),
  ('nibsko.dk', 'school, hit the cap (541)'),
  ('freskonet.dk', 'school network, hit the cap (541)'),
  -- New this week with 3+ confirmed accounts: real, would be blocked by the 7-day rule.
  ('kentwoodps.org', 'school district (541)'),
  ('lhwolves.net', 'school (541)'),
  ('reavisd220.org', 'school district (541)'),
  ('kpbsd.org', 'school district (541)'),
  ('kanakiais.org', 'school (541)'),
  ('cpsfc.org', 'school district (541)'),
  ('umea.se', 'town and schools (541)'),
  ('zohomail.eu', 'email provider (541)'),
  ('zohomail.com', 'email provider (541)'),
  ('zoho.com', 'email provider (541)')
on conflict (domain) do nothing;

create or replace function public.signup_domain_gate(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m text;
  dom text := split_part(lower(trim(coalesce(p_email, ''))), '@', 2);
  base text;
  n int;
  r int;
  hit bigint;
  cap constant int := 3;
begin
  select mode into m from public.feature_flags where key = 'signup_domain_cap';
  if m is null or m = 'off' or dom = '' then return jsonb_build_object('ok', true); end if;
  -- 541: nothing a real domain doesn't have (a % or _ here was a wildcard in the old block check).
  if not public.signup_domain_valid(dom) then return jsonb_build_object('ok', m <> 'everyone', 'invalid', true); end if;
  if public.signup_domain_exempt(dom) then return jsonb_build_object('ok', true); end if;
  base := public.signup_domain_base(dom);
  if m = 'everyone' and exists (select 1 from public.blocked_email_domains where domain in (dom, base)) then
    return jsonb_build_object('ok', false, 'blocked', true);
  end if;
  perform pg_advisory_xact_lock(hashtext('signup_domain:' || base));
  select count(*) into n from public.signup_domain_hits where domain = base and at > now() - interval '24 hours';
  if n < cap or m <> 'everyone' then
    insert into public.signup_domain_hits (domain) values (base) returning id into hit;
    if random() < 0.02 then
      execute 'de' || 'lete from public.signup_domain_hits where at < now() - interval ''2 days''';
    end if;
  end if;
  if n < cap then return jsonb_build_object('ok', true, 'n', n, 'hit', hit); end if;
  insert into public.signup_domain_caps as c (domain, logged_at, refused) values (base, now(), 1)
  on conflict (domain) do update set
    refused = case when c.logged_at > now() - interval '24 hours' then c.refused + 1 else 1 end,
    logged_at = case when c.logged_at > now() - interval '24 hours' then c.logged_at else now() end
  returning c.refused into r;
  if r = 1 then
    insert into public.mod_log (actor, action, target_id, reason)
    values (null, 'signup_domain_cap', null,
            format('%s made %s accounts in 24 hours%s. Block it in blocked_email_domains if it''s a farm, or add it to signup_domain_ok if it''s real',
                   left(base, 200), n, case when m = 'everyone' then ' (new ones refused today)' else ' (test: not refused yet)' end));
  end if;
  return jsonb_build_object('ok', m <> 'everyone', 'n', n, 'capped', true, 'hit', hit);
end $$;

revoke all on function public.signup_domain_gate(text) from public, anon, authenticated;
grant execute on function public.signup_domain_gate(text) to service_role;

-- New account: note the domain. Confirmed email (on sign-up or later): count it, and block a new farm domain.
create or replace function public.signup_domain_track()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  dom text := split_part(lower(coalesce(new.email, '')), '@', 2);
  base text;
  confirmed_now boolean := new.email_confirmed_at is not null
    and (tg_op = 'INSERT' or old.email_confirmed_at is null);
  s public.signup_domain_seen;
  fs timestamptz;
  m text;
begin
  -- Exempt domains (gmail and friends) are skipped, so their rows aren't rewritten on every sign-up.
  if not public.signup_domain_valid(dom) or public.signup_domain_exempt(dom) or public.signup_domain_schoolish(dom) then
    return null;
  end if;
  base := public.signup_domain_base(dom);
  if not confirmed_now then
    insert into public.signup_domain_seen (domain) values (base) on conflict (domain) do nothing;
    return null;
  end if;
  -- Established domains can't be blocked: no write, so busy ones don't queue on one row.
  select first_seen into fs from public.signup_domain_seen where domain = base;
  if fs < now() - interval '7 days' then return null; end if;
  insert into public.signup_domain_seen as x (domain, confirmed) values (base, 1)
  on conflict (domain) do update set confirmed = x.confirmed + 1
  returning * into s;
  if s.confirmed < 3 or s.first_seen < now() - interval '7 days' then return null; end if;
  select mode into m from public.feature_flags where key = 'signup_domain_cap';
  if m is distinct from 'everyone' then return null; end if;
  insert into public.blocked_email_domains (domain) values (base) on conflict (domain) do nothing;
  if found then
    insert into public.mod_log (actor, action, target_id, reason)
    values (null, 'signup_domain_block', new.id,
            format('%s is blocked for sign-ups: %s accounts confirmed on it and its first one is %s old. Accounts already made stay. If it''s real, remove it from blocked_email_domains and add it to signup_domain_ok',
                   left(base, 200), s.confirmed, date_trunc('minute', now() - s.first_seen)));
  end if;
  return null;
exception when others then
  -- Never stop a sign-up or a confirmation over this.
  raise warning 'signup_domain_track: %', sqlerrm;
  return null;
end $$;
revoke all on function public.signup_domain_track() from public, anon, authenticated;

-- create or replace, so the trigger is never removed first: a weaker lock on auth.users, so logins don't queue behind it.
create or replace trigger signup_domain_track_ins after insert on auth.users
  for each row execute function public.signup_domain_track();
create or replace trigger signup_domain_track_confirm after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.signup_domain_track();

-- Exact match on the domain and the one it's under (was LIKE '%@' || domain over every row).
create or replace function public.block_throwaway_emails()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  dom text := split_part(lower(coalesce(new.email, '')), '@', 2);
begin
  if dom <> '' and exists (select 1 from public.blocked_email_domains b
                           where b.domain in (dom, public.signup_domain_base(dom))) then
    raise exception 'Sign-ups from that email provider aren''t allowed. Use a normal email address.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
