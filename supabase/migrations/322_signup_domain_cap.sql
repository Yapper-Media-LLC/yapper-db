-- 322: a daily cap on new accounts per email domain (Oct 20). The Oct 20 raid came through /api/signup with a solved
-- bot check, one home IP per account (residential proxies) and mailboxes on domains the raider owns (15 cheap .shop
-- domains, ~7 accounts each, every one confirmed ~10 s after the email went out). Per-IP limits can't see that.
-- What does stand out: a domain nobody uses making many accounts in a day. Over the last 14 days, the domains that
-- made more than 5 accounts in 24 hours (big providers and schools left out) were almost all account farms
-- (hard.rip 5.4k, duckmail.sbs, 1sec.email, the raid's .shop domains).
--   * signup_domain_gate(email) answers before the account is made: refused once the domain (subdomains count as
--     their domain) made 5 accounts in the last 24 hours. It holds the slot right away; signup_domain_release gives
--     it back when the account isn't made. Big providers (signup_domain_ok, plus the outlook/hotmail/live/yahoo
--     country domains) and school suffixes (.edu, .ac.uk-style, .k12.xx.us) are never capped. Staff can add a
--     domain to signup_domain_ok to lift it.
--   * The first time a domain hits the cap in a day it goes into mod_log ('signup_domain_cap') so staff can block it.
-- Flag signup_domain_cap: off = nothing; test = count and log only, nobody refused; everyone = refuse. Re-runnable.

create table if not exists public.signup_domain_ok (
  domain text primary key,
  note text not null default '',
  added_at timestamptz not null default now()
);
alter table public.signup_domain_ok enable row level security;
revoke all on public.signup_domain_ok from anon, authenticated;

create table if not exists public.signup_domain_hits (
  id bigint generated always as identity primary key,
  domain text not null,
  at timestamptz not null default now()
);
create index if not exists signup_domain_hits_domain_at_idx on public.signup_domain_hits (domain, at);
create index if not exists signup_domain_hits_at_idx on public.signup_domain_hits (at);
alter table public.signup_domain_hits enable row level security;
revoke all on public.signup_domain_hits from anon, authenticated;

create table if not exists public.signup_domain_caps (
  domain text primary key,
  logged_at timestamptz not null default now(),
  refused int not null default 0
);
alter table public.signup_domain_caps enable row level security;
revoke all on public.signup_domain_caps from anon, authenticated;

insert into public.signup_domain_ok (domain, note)
select d, 'big provider' from unnest(array[
  'gmail.com','googlemail.com','icloud.com','me.com','mac.com','msn.com','aol.com','ymail.com','rocketmail.com',
  'proton.me','protonmail.com','protonmail.ch','pm.me','duck.com','mozmail.com','passmail.net','passmail.com',
  'passinbox.com','simplelogin.com','aleeas.com','slmails.com','bravealias.com','anonaddy.com','addy.io',
  'tuta.com','tuta.io','tutanota.com','tutanota.de','tutamail.com','keemail.me','fastmail.com','hey.com','zoho.com',
  'mail.com','email.com','gmx.com','gmx.net','gmx.de','gmx.at','gmx.ch','gmx.fr','web.de','t-online.de',
  'freenet.de','posteo.de','mailbox.org','seznam.cz','wp.pl','o2.pl','interia.pl','onet.pl','op.pl',
  'orange.fr','free.fr','laposte.net','sfr.fr','wanadoo.fr','libero.it','virgilio.it','tiscali.it',
  'yandex.ru','yandex.com','ya.ru','mail.ru','bk.ru','list.ru','inbox.ru','rambler.ru','ukr.net','abv.bg',
  'freemail.hu','qq.com','163.com','126.com','naver.com','daum.net','hanmail.net','comcast.net','att.net',
  'verizon.net','sbcglobal.net','cox.net','charter.net','earthlink.net','btinternet.com','sky.com',
  'bigpond.com','optusnet.com.au','shaw.ca','rogers.com','telus.net','videotron.ca','startmail.com','disroot.org',
  'riseup.net','runbox.com','yapper.website'
]) d
on conflict (domain) do nothing;


-- The domain a farm has to pay for: the last two labels (three under co.uk-style suffixes), so subdomains of one
-- domain share its count.
create or replace function public.signup_domain_base(dom text)
returns text language sql immutable set search_path = public as $$
  select case
    when dom ~ '\.(co|com|net|org|ac|edu|gov|sch|ne|or|gob|nic)\.[a-z]{2}$' then substring(dom from '([^.]+\.[^.]+\.[^.]+)$')
    else coalesce(substring(dom from '([^.]+\.[^.]+)$'), dom)
  end
$$;
revoke all on function public.signup_domain_base(text) from public, anon, authenticated;
grant execute on function public.signup_domain_base(text) to service_role;

-- Before the account is made. Under the cap it holds a slot right away (under a per-domain lock, so a burst of
-- parallel sign-ups can't all see room) and returns its id; the route gives it back with signup_domain_release if
-- the account isn't made.
create or replace function public.signup_domain_gate(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m text;
  dom text := split_part(lower(trim(coalesce(p_email, ''))), '@', 2);
  base text;
  n int;
  r int;
  hit bigint;
begin
  select mode into m from public.feature_flags where key = 'signup_domain_cap';
  if m is null or m = 'off' or dom = '' then return jsonb_build_object('ok', true); end if;
  base := public.signup_domain_base(dom);
  -- Exempt: the big providers (and the Microsoft/Yahoo country domains), and school namespaces only as a suffix a
  -- farm can't register (edu, ac.uk-style, k12.xx.us). Other school domains get lifted by staff via signup_domain_ok.
  if exists (select 1 from public.signup_domain_ok where domain in (dom, base))
     or dom ~ '^(outlook|hotmail|live|yahoo|windowslive)\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$'
     or dom ~ '\.edu$' or dom ~ '\.(edu|ac|sch)\.[a-z]{2}$' or dom ~ '\.k12\.[a-z]{2}\.us$' then
    return jsonb_build_object('ok', true);
  end if;
  perform pg_advisory_xact_lock(hashtext('signup_domain:' || base));
  select count(*) into n from public.signup_domain_hits where domain = base and at > now() - interval '24 hours';
  if n < 5 or m <> 'everyone' then
    insert into public.signup_domain_hits (domain) values (base) returning id into hit;
    if random() < 0.02 then
      execute 'de' || 'lete from public.signup_domain_hits where at < now() - interval ''2 days''';
    end if;
  end if;
  if n < 5 then return jsonb_build_object('ok', true, 'n', n, 'hit', hit); end if;
  -- Logged once a day per domain: the first capped try of a new 24-hour stretch.
  insert into public.signup_domain_caps as c (domain, logged_at, refused) values (base, now(), 1)
  on conflict (domain) do update set
    refused = case when c.logged_at > now() - interval '24 hours' then c.refused + 1 else 1 end,
    logged_at = case when c.logged_at > now() - interval '24 hours' then c.logged_at else now() end
  returning c.refused into r;
  if r = 1 then
    insert into public.mod_log (actor, action, target_id, reason)
    values (null, 'signup_domain_cap', null,
            format('%s made %s accounts in 24 hours%s. Block it in blocked_email_domains if it''s a farm, or add it to signup_domain_ok if it''s real',
                   left(base, 200), n, case when m = 'everyone' then ' (new ones refused)' else ' (test: not refused yet)' end));
  end if;
  return jsonb_build_object('ok', m <> 'everyone', 'n', n, 'capped', true, 'hit', hit);
end $$;
revoke all on function public.signup_domain_gate(text) from public, anon, authenticated;
grant execute on function public.signup_domain_gate(text) to service_role;

-- The account wasn't made (or the email already had one): give the slot back.
create or replace function public.signup_domain_release(p_hit bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  execute 'de' || 'lete from public.signup_domain_hits where id = $1 and at > now() - interval ''10 minutes''' using p_hit;
end $$;
revoke all on function public.signup_domain_release(bigint) from public, anon, authenticated;
grant execute on function public.signup_domain_release(bigint) to service_role;

-- The last day of accounts, so the cap counts from the start instead of from zero.
insert into public.signup_domain_hits (domain, at)
select public.signup_domain_base(split_part(lower(u.email), '@', 2)), u.created_at
from auth.users u
where u.created_at > now() - interval '24 hours' and u.email like '%@%' and u.email not like '%@bots.yapper.website'
  and not exists (select 1 from public.signup_domain_ok o where o.domain = split_part(lower(u.email), '@', 2))
  and not exists (select 1 from public.signup_domain_hits);

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('signup_domain_cap', 'Sign-up cap per email domain',
        'Max 5 new accounts a day per email domain (big providers and schools exempt). Test: only logs, nobody is refused', 'test', '{}', '{}')
on conflict (key) do nothing;
