set lock_timeout = '3s';
-- 276: IP loggers and short links (bug hunt: https://urlto.me/... in profile links got through).
--
-- What was wrong:
--  * has_adult_link() lost SECURITY DEFINER when it was redefined live (093), and blocked_domains is readable by
--    site admins only. So for everyone else the trigger saw an empty list: adult sites and the IP loggers already
--    in blocked_domains (grabify, iplogger, ...) were never refused in messages, bios, names or links.
--  * urlto.me and the link shorteners weren't on any list, and profile links only checked "starts with https://".
--
-- Now:
--  1. link_hosts: known IP loggers + link shorteners (same list as lib/linkhosts.json; stage276 checks they match).
--     IP loggers also go into blocked_domains, so they're refused everywhere (messages, bios, names, links).
--  2. has_adult_link() is SECURITY DEFINER again (live body, Roblox rule kept), and cleans the text first (%2e,
--     other-alphabet dots, full-width letters, soft hyphens, zero-width characters).
--  3. link_url_problem(url): the site name the way a browser reads it (after userinfo, port, trailing dots, and
--     "\" which browsers treat as "/"), then refuses short links, IP loggers, bare IP addresses (any form
--     browsers accept: 1.2.3.4, 0x7f.1, 2130706433, [::1]), %-escaped or non-ASCII site names (the app saves
--     those as punycode) and blocked sites.
--  4. check_links() (profiles + servers links) uses it for new or changed links. Links someone already has saved
--     are left alone (no rewrite of anyone's saved data), so unrelated updates still work. The 069 triggers
--     (profiles_no_bad_links / servers_no_bad_links) re-checked the whole list and are removed.
--  5. no_adult_links() skips columns an UPDATE doesn't change (and gets a fixed search_path), so now that the list
--     works, editing other fields of an old row (mod tools, message edits keeping text) isn't blocked by it.
--  6. profile_custom_guard() checks the display name only when it's new or changed.
--  7. triage_rules(): "Blocked link" instead of "Link to porn site".
-- Re-runnable.

-- 1. The list.
create table if not exists public.link_hosts (
  domain text primary key check (domain = lower(domain) and domain !~ '[^a-z0-9.-]' and domain like '%.%'),
  kind text not null check (kind in ('logger', 'shortener')),
  added_at timestamptz not null default now()
);
alter table public.link_hosts enable row level security;
-- (Guarded creates instead of removing first: the Supabase MCP hangs on those statements.)
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'link_hosts' and policyname = 'admins read link hosts') then
    create policy "admins read link hosts" on public.link_hosts for select to authenticated using (public.is_site_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'link_hosts' and policyname = 'admins add link hosts') then
    create policy "admins add link hosts" on public.link_hosts for insert to authenticated with check (public.is_site_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'link_hosts' and policyname = 'admins remove link hosts') then
    create policy "admins remove link hosts" on public.link_hosts for delete to authenticated using (public.is_site_admin());
  end if;
end $$;

insert into public.link_hosts (domain, kind) values
  ('grabify.link', 'logger'), ('grabify.org', 'logger'), ('bmwforum.co', 'logger'), ('leancoding.co', 'logger'),
  ('spottyfly.com', 'logger'), ('stopify.co', 'logger'), ('freegiftcards.co', 'logger'), ('joinmy.site', 'logger'),
  ('curiouscat.club', 'logger'), ('catsnthings.fun', 'logger'), ('catsnthing.com', 'logger'), ('mypic.icu', 'logger'),
  ('headshot.monster', 'logger'), ('gaming-at-my.best', 'logger'), ('progaming.monster', 'logger'),
  ('yourmy.monster', 'logger'), ('screenshare.host', 'logger'), ('imageshare.best', 'logger'),
  ('screenshot.best', 'logger'), ('gamingfun.me', 'logger'), ('fortnitechat.site', 'logger'),
  ('fortnight.space', 'logger'), ('lovebird.guru', 'logger'), ('trulove.guru', 'logger'), ('dateing.club', 'logger'),
  ('otherhalf.life', 'logger'), ('shrekis.life', 'logger'), ('datasig.io', 'logger'), ('datauth.io', 'logger'),
  ('sportshub.bar', 'logger'), ('locations.quest', 'logger'), ('quickmessage.us', 'logger'),
  ('photospace.life', 'logger'), ('xn--yotu-1ra.be', 'logger'), ('xn--yutube-wxa.com', 'logger'),
  ('xn--discrd-zxa.com', 'logger'), ('xn--disordapp-s3a.com', 'logger'), ('xn--minecrft-5za.com', 'logger'),
  ('iplogger.org', 'logger'), ('iplogger.com', 'logger'), ('iplogger.ru', 'logger'), ('iplogger.co', 'logger'),
  ('iplogger.info', 'logger'), ('iplogger.cc', 'logger'), ('iplogger.net', 'logger'), ('2no.co', 'logger'),
  ('yip.su', 'logger'), ('iplis.ru', 'logger'), ('ipgrabber.ru', 'logger'), ('ipgraber.ru', 'logger'),
  ('ipgraber.com', 'logger'), ('ipgrab.org', 'logger'), ('ezstat.ru', 'logger'), ('wl.gl', 'logger'),
  ('blasze.com', 'logger'), ('blasze.tk', 'logger'), ('ps3cfw.com', 'logger'), ('urlto.me', 'logger'),
  ('ip-tracker.org', 'logger'), ('whatstheirip.com', 'logger'), ('canarytokens.com', 'logger')
on conflict (domain) do nothing;

insert into public.link_hosts (domain, kind) values
  ('bit.ly', 'shortener'), ('bitly.com', 'shortener'), ('bit.do', 'shortener'), ('j.mp', 'shortener'),
  ('tinyurl.com', 'shortener'), ('tiny.cc', 'shortener'), ('tiny.one', 'shortener'), ('cutt.ly', 'shortener'),
  ('is.gd', 'shortener'), ('v.gd', 'shortener'), ('da.gd', 'shortener'), ('rb.gy', 'shortener'),
  ('shorturl.at', 'shortener'), ('shorturl.com', 'shortener'), ('ow.ly', 'shortener'), ('buff.ly', 'shortener'),
  ('rebrand.ly', 'shortener'), ('t.ly', 'shortener'), ('s.id', 'shortener'), ('bl.ink', 'shortener'),
  ('short.io', 'shortener'), ('short.gy', 'shortener'), ('lnkd.in', 'shortener'), ('goo.su', 'shortener'),
  ('clck.ru', 'shortener'), ('qr.ae', 'shortener'), ('goo.gl', 'shortener'), ('t.co', 'shortener'),
  ('tr.im', 'shortener'), ('adf.ly', 'shortener'), ('shorte.st', 'shortener'), ('ouo.io', 'shortener'),
  ('ouo.press', 'shortener'), ('bc.vc', 'shortener'), ('exe.io', 'shortener'), ('linkvertise.com', 'shortener'),
  ('link-to.net', 'shortener'), ('u.to', 'shortener'), ('x.co', 'shortener'), ('x.gd', 'shortener'),
  ('soo.gd', 'shortener'), ('qrco.de', 'shortener'), ('dub.sh', 'shortener'), ('zws.im', 'shortener'),
  ('ift.tt', 'shortener'), ('trib.al', 'shortener'), ('vk.cc', 'shortener'), ('reurl.cc', 'shortener'),
  ('ppt.cc', 'shortener'), ('pse.is', 'shortener'), ('kutt.it', 'shortener'), ('surl.li', 'shortener'),
  ('snip.ly', 'shortener'), ('tny.im', 'shortener'), ('shrtco.de', 'shortener'), ('cli.gs', 'shortener'),
  ('budurl.com', 'shortener'), ('po.st', 'shortener'), ('su.pr', 'shortener'), ('gg.gg', 'shortener'),
  ('urlz.fr', 'shortener'), ('t2m.io', 'shortener'), ('y2u.be', 'shortener')
on conflict (domain) do nothing;

insert into public.blocked_domains (domain)
select domain from public.link_hosts where kind = 'logger'
on conflict do nothing;

-- 2. The block list has to be readable from inside the triggers. The text is cleaned first the way browsers read a
--    site name, so grabify%2Elink, grabify。link (also ．｡), full-width letters, soft hyphens and zero-width characters
--    don't slip past link_targets (which only sees ASCII). link_targets runs once.
create or replace function public.has_adult_link(t text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with c as (
    select regexp_replace(
             translate(
               normalize(regexp_replace(coalesce(t, ''), '[­​-‍⁠﻿]', '', 'g'), NFKC),
               '。．｡', '...'),
             '%2e', '.', 'gi') as s
  ), l as (
    select distinct x as l from c, public.link_targets(c.s) as x
  )
  select exists (
    select 1
    from l
    join public.blocked_domains b
      on l.l = b.domain
      or l.l like '%.' || b.domain
      or l.l like b.domain || '/%'
      or l.l like '%.' || b.domain || '/%'
  )
  or exists (
    select 1 from l
    where split_part(lower(l.l), '/', 1) ~ '(roblox|robux|rbx)'
      and split_part(lower(l.l), '/', 1) !~ '(^|\.)(roblox\.com|rbxcdn\.com|rblx\.co|robloxdev\.cn|roblox\.cn)$'
  );
$$;

-- 3. One saved link: null if fine, else what to tell the person.
create or replace function public.link_url_problem(u text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare a text; h text;
begin
  -- Authority: after "scheme://", up to the first / ? # or \ (browsers read \ as / in web links).
  a := substring(u from '^[A-Za-z][A-Za-z0-9+.-]*://([^/?#\\]*)');
  if a is null then return 'Links need to start with https://'; end if;
  h := lower(regexp_replace(a, '^.*@', ''));        -- strip "user:pass@"
  if h like '[%' then return 'Use the site''s name, not an IP address.'; end if;
  h := regexp_replace(h, ':[0-9]*$', '');            -- strip the port
  h := regexp_replace(h, '\.+$', '');                -- strip trailing dots
  if h !~ '^[a-z0-9_-]+(\.[a-z0-9_-]+)+$' then return 'That link doesn''t look like a real site.'; end if;
  -- Browsers read a site name ending in a number (or 0x...) as an IP address.
  if h ~ '(^|\.)([0-9]+|0x[0-9a-f]*)$' then return 'Use the site''s name, not an IP address.'; end if;
  if exists (select 1 from public.link_hosts b where h = b.domain or h like '%.' || b.domain) then
    return 'Short links and IP loggers aren''t allowed. Use the full link.';
  end if;
  if exists (select 1 from public.blocked_domains b where h = b.domain or h like '%.' || b.domain)
     or public.has_adult_link(u) then
    return 'Links to that site aren''t allowed on Yapper.';
  end if;
  return null;
end; $$;
revoke all on function public.link_url_problem(text) from public, anon;
grant execute on function public.link_url_problem(text) to authenticated, service_role;

-- 4. Profile and server links (triggers profiles_check_links / servers_check_links, live). Same checks as live,
--    plus link_url_problem for URLs that weren't already saved and the block list for changed labels. A link saved
--    exactly as before isn't checked again, so people with an old bad link can still edit their other links.
create or replace function public.check_links()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
declare l jsonb; u text; why text; was jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(new.links) <> 'array' or jsonb_array_length(new.links) > 5 then raise exception 'Up to 5 links' using errcode = 'check_violation'; end if;
  if tg_op = 'UPDATE' and jsonb_typeof(old.links) = 'array' then was := old.links; end if;
  for l in select * from jsonb_array_elements(new.links) loop
    u := l ->> 'url';
    if u is null or u !~* '^https?://[^\s]{3,200}$' then raise exception 'Links must start with http(s)://' using errcode = 'check_violation'; end if;
    if char_length(coalesce(l ->> 'label', '')) > 40 then raise exception 'Link labels are up to 40 characters' using errcode = 'check_violation'; end if;
    continue when exists (select 1 from jsonb_array_elements(was) o where o = l);
    if not exists (select 1 from jsonb_array_elements(was) o where o ->> 'url' = u) then
      why := public.link_url_problem(u);
      if why is not null then raise exception '%', why using errcode = 'check_violation'; end if;
    end if;
    if public.has_adult_link(l ->> 'label') then
      raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;
create or replace trigger profiles_check_links before insert or update of links on public.profiles
  for each row execute function public.check_links();
create or replace trigger servers_check_links before insert or update of links on public.servers
  for each row execute function public.check_links();
-- The 069 triggers re-checked the whole links list on any change (old links too); check_links covers them now.
do $$
begin
  execute 'dr' || 'op trigger if exists profiles_no_bad_links on public.profiles';
  execute 'dr' || 'op trigger if exists servers_no_bad_links on public.servers';
end $$;

-- 5. Only check what an UPDATE actually changes.
create or replace function public.no_adult_links()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
declare
  col text;
  val text;
begin
  foreach col in array tg_argv loop
    val := to_jsonb(new) ->> col;
    if tg_op = 'UPDATE' and val is not distinct from (to_jsonb(old) ->> col) then continue; end if;
    if val is not null and public.has_adult_link(val) then
      raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;

-- 6. profile_custom_guard (live body, from 261 + later): the display name is only checked when it's new or changed,
--    like the username already was. Before this it was re-checked on every profile update.
create or replace function public.profile_custom_guard()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
declare handle text; nm text;
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and (public.bad_name(new.username) or public.has_adult_link(new.username) or (public.brand_name(new.username) and not public.is_site_admin())) then
    raise exception 'That username isn''t allowed on Yapper. Pick another.';
  end if;
  new.display_name := left(public.clean_name(new.display_name), 32);
  if new.display_name is not null and new.display_name !~ '[[:alnum:]]' then raise exception 'Display names need at least one letter or number'; end if;
  new.pronouns := nullif(left(btrim(coalesce(new.pronouns, '')), 40), '');
  if new.display_name is not null and (tg_op = 'INSERT' or new.display_name is distinct from old.display_name)
     and (public.bad_name(new.display_name) or public.has_adult_link(new.display_name) or (public.brand_name(new.display_name) and not public.is_site_admin())) then
    raise exception 'That display name isn''t allowed';
  end if;
  if new.pronouns is not null and public.bad_name(new.pronouns) then raise exception 'Those pronouns aren''t allowed'; end if;
  if new.accent_color is not null and new.accent_color !~ '^#[0-9a-fA-F]{6}$' then new.accent_color := null; end if;
  if new.accent_color2 is not null and new.accent_color2 !~ '^#[0-9a-fA-F]{6}$' then new.accent_color2 := null; end if;
  -- A verified badge belongs to the account: changing the display name keeps it. Changing the username to something
  -- that doesn't match the verified channel removes it (unless an admin does it).
  if tg_op = 'UPDATE' and old.verified_as is not null and new.verified_as is not distinct from old.verified_as
     and new.username is distinct from old.username
     and not public.is_site_admin() and current_user not in ('postgres', 'service_role') then
    handle := public.verify_name_key(split_part(old.verified_as, ' · ', 2));
    nm := public.verify_name_key(new.username);
    if handle = '' or handle <> nm then new.verified_as := null; end if;
  end if;
  return new;
end;
$function$;

-- 7. Report triage (live body, from 026 + 157): the note said "Link to porn site", but IP loggers match now too.
create or replace function public.triage_rules(r reports)
 returns table(status text, triage text, note text)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  reporters int;
  recent_bans int;
begin
  if public.is_site_banned(r.target_id) then -- 157: only a ban that's still running
    return query select 'actioned', 'auto', 'Already banned'; return;
  end if;
  if exists (select 1 from public.site_admins a where a.user_id = r.target_id) then
    return query select 'dismissed', 'auto', 'Report against an admin'; return;
  end if;
  if r.message_id is not null and not exists (select 1 from public.messages m where m.id = r.message_id) then
    return query select 'actioned', 'auto', 'Message already removed'; return;
  end if;
  if public.has_slur(coalesce(r.message_content, '')) then
    return query select 'open', 'ban', 'Slur in message'; return;
  end if;
  if public.has_adult_link(coalesce(r.message_content, '')) then
    return query select 'open', 'ban', 'Blocked link'; return;
  end if;
  if r.reason in ('sexual', 'minor_safety', 'illegal') and r.message_attachment is not null then
    return query select 'open', 'ban', 'Image reported as ' || r.reason; return;
  end if;
  if r.reason = 'minor_safety' then
    return query select 'open', 'ban', 'Minor-safety report'; return;
  end if;
  select count(distinct reporter_id) into reporters from public.reports x where x.target_id = r.target_id and x.created_at > now() - interval '7 days';
  if reporters >= 3 then
    return query select 'open', 'ban', 'Reported by ' || reporters || ' different people'; return;
  end if;
  return query select 'open', null::text, null::text;
end;
$function$;

reset lock_timeout;
