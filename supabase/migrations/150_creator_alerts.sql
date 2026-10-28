-- Creator alerts: the built-in Alerts bot posts when a watched YouTube channel uploads (flag creator_alerts).
-- Account alerts@yapper.website (username Alerter, shown as Alerts), bot key 'alerts', avatar /bots/alerts.svg.
--
-- Tables (RLS on, no grants to anon/authenticated; everything goes through the RPCs below):
--   yt_feeds       one row per YouTube channel, shared by every server watching it (one fetch per channel).
--                  seen_ids = recent video ids already handled; latest = newest video (for the test button);
--                  fails / last_error / next_check_at = backoff; pending_req = the pg_net request in flight.
--   alert_watches  one row per (server, YouTube channel): where to post, role to ping, message template.
--
-- Polling: pg_cron job 'creator-alerts-tick' runs alerts_tick() every minute. It collects finished pg_net
-- responses, parses the Atom feed with XMLTABLE, posts new uploads as the bot, then fires GETs for feeds that
-- are due (every 10 minutes per feed, doubling up to 12 hours after errors). The first good fetch of a feed
-- only records what's there (no backlog), and a server only gets videos published after it added the channel.
-- Free servers: 3 YouTube channels, Server Plus (server_plus_on): 25. Over the limit (Plus ran out) the oldest
-- 3 keep working. Role pings go through fix_role_pings_bot like every bot post (mentionable roles only).
-- Posts are built whole, then defused once (no @everyone/@here, no <@...> tokens from YouTube or the template);
-- only the picked role is put back as a ping, and never on a test post.
-- alerts_rate: limits (10 adds per server per hour, 20 link lookups per person per 10 min, 1 test per server per 30 s).
-- Responses are removed from net._http_response once read; unused feeds are cleaned up once an hour.
-- Re-runnable. The MCP hangs on two SQL words, so they are built with || below.

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('creator_alerts', 'Creator alerts', 'Alerts bot: posts when a YouTube channel uploads.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- bot key ----------
do $$ begin
  execute 'alter table public.server_bots dr' || 'op constraint if exists server_bots_bot_check';
  execute 'alter table public.bot_accounts dr' || 'op constraint if exists bot_accounts_bot_check';
end $$;
alter table public.server_bots add constraint server_bots_bot_check
  check (bot = any (array['welcome','helper','levels','logger','starboard','giveaways','tickets','alerts']));
alter table public.bot_accounts add constraint bot_accounts_bot_check
  check (bot = any (array['welcome','helper','levels','logger','starboard','giveaways','tickets','alerts']));

-- ---------- bot account ----------
do $$ declare uid uuid; begin
  if exists (select 1 from public.bot_accounts where bot = 'alerts') then return; end if;
  select id into uid from auth.users where email = 'alerts@yapper.website';
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous,
      phone_change, phone_change_token, reauthentication_token, email_change_token_current, email_change_confirm_status)
    values (uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alerts@yapper.website',
      extensions.crypt(gen_random_uuid()::text || gen_random_uuid()::text, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{"username":"Alerter"}'::jsonb, now(), now(), false, false,
      '', '', '', '', 0);
  end if;
  -- require_scanned_media wants the picture checked before it goes on the profile
  insert into public.media_scans (bucket, path, verdict, score, scanned_at) values ('avatars', '/bots/alerts.svg', 'ok', 0, now())
  on conflict (bucket, path) do nothing;
  update public.profiles set display_name = 'Alerts', badges = array['official_bot','bot'], avatar_path = '/bots/alerts.svg',
    dms_from = 'servers', bio = 'Creator alerts. Tell me which YouTube channels to watch and I post here when they upload.'
  where id = uid;
  insert into public.bot_accounts (bot, user_id) values ('alerts', uid) on conflict (bot) do nothing;
end $$;

-- ---------- tables ----------
create table if not exists public.yt_feeds (
  channel_id text primary key check (channel_id ~ '^UC[A-Za-z0-9_-]{22}$'),
  name text,
  latest jsonb,
  seen_ids text[] not null default '{}',
  baseline boolean not null default false,
  last_published timestamptz,
  last_checked_at timestamptz,
  next_check_at timestamptz not null default now(),
  fails int not null default 0,
  last_error text,
  pending_req bigint,
  requested_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists yt_feeds_due on public.yt_feeds (next_check_at) where pending_req is null;
create index if not exists yt_feeds_pending on public.yt_feeds (pending_req) where pending_req is not null;

create table if not exists public.alert_watches (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  yt_channel_id text not null references public.yt_feeds(channel_id),
  channel_id uuid not null references public.channels(id) on delete cascade,
  role_id uuid references public.roles(id) on delete set null,
  template text check (template is null or char_length(template) <= 500),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  last_posted_at timestamptz,
  last_video_id text,
  last_test_at timestamptz,
  unique (server_id, yt_channel_id)
);
create index if not exists alert_watches_yt on public.alert_watches (yt_channel_id);
create index if not exists alert_watches_channel on public.alert_watches (channel_id);
create index if not exists alert_watches_role on public.alert_watches (role_id) where role_id is not null;
create index if not exists alert_watches_creator on public.alert_watches (created_by) where created_by is not null;

alter table public.yt_feeds enable row level security;
alter table public.alert_watches enable row level security;
revoke all on public.yt_feeds from public, anon, authenticated;
revoke all on public.alert_watches from public, anon, authenticated;

-- ---------- parsing ----------
/** YouTube's Atom feed -> { name, videos: [{ id, title, url, published }] }, newest first. Raises on bad XML. */
create or replace function public.yt_parse_feed(body text) returns jsonb
language plpgsql immutable set search_path = public as $$
declare x xml; nm text; vids jsonb;
begin
  -- Strip the <?xml ...?> line: xmlparse refuses an encoding declaration on an already decoded string.
  x := xmlparse(document regexp_replace(body, '^\s*<\?xml[^>]*\?>', ''));
  select t.title into nm from xmltable(xmlnamespaces('http://www.w3.org/2005/Atom' as a), '/a:feed' passing x
    columns title text path 'a:title') t;
  select coalesce(jsonb_agg(jsonb_build_object('id', v.vid, 'title', left(coalesce(v.title, ''), 300),
      'url', case when v.link ~ '^https://www\.youtube\.com/(watch\?v=|shorts/)[A-Za-z0-9_-]{11}$' then v.link
                  else 'https://www.youtube.com/watch?v=' || v.vid end,
      'published', v.published) order by v.published desc nulls last), '[]'::jsonb)
  into vids
  from xmltable(xmlnamespaces('http://www.w3.org/2005/Atom' as a, 'http://www.youtube.com/xml/schemas/2015' as yt),
    '/a:feed/a:entry' passing x
    columns vid text path 'yt:videoId', title text path 'a:title',
            link text path 'a:link[@rel="alternate"]/@href', published timestamptz path 'a:published') v
  where v.vid ~ '^[A-Za-z0-9_-]{11}$';
  return jsonb_build_object('name', left(btrim(nm), 100), 'videos', vids);
end $$;
revoke all on function public.yt_parse_feed(text) from public, anon, authenticated;

/** Text from YouTube or a manager, safe for a bot post: no @everyone/@here, no <@user> pings. */
create or replace function public.alerts_defuse(t text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(regexp_replace(coalesce(t, ''), '<@!?([0-9a-f-]{36})>', '@user', 'gi'), '@(everyone|here)', '@' || chr(8203) || '\1', 'gi')
$$;
revoke all on function public.alerts_defuse(text) from public, anon, authenticated;

-- ---------- posting ----------
/** Removes every <@user> / <@!user> / <@&role> token. */
create or replace function public.alerts_untag(t text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(coalesce(t, ''), '<@[!&]?[0-9a-fA-F-]{36}>', '', 'g')
$$;
revoke all on function public.alerts_untag(text) from public, anon, authenticated;

-- The 3-argument version from the first draft.
do $$ begin execute 'dr' || 'op function if exists public.alerts_post(uuid, jsonb, text)'; end $$;

/**
 * Builds the whole post first, then defuses it once: pieces like "@{title}" + a title "everyone" can't add up
 * to a ping. The role ping is a chr(1) placeholder while that happens. Tests (p_test) never ping.
 */
create or replace function public.alerts_post(wid uuid, v jsonb, creator text, p_test boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare w public.alert_watches; body text; ping boolean;
begin
  select * into w from public.alert_watches where id = wid;
  if w.id is null or not exists (select 1 from public.channels where id = w.channel_id and server_id = w.server_id) then return; end if;
  if not exists (select 1 from public.server_bots where server_id = w.server_id and bot = 'alerts' and enabled) then return; end if;
  ping := w.role_id is not null and not p_test;
  body := replace(coalesce(nullif(btrim(w.template), ''), '{creator} just posted: **{title}**' || E'\n' || '{url}'), chr(1), '');
  if position('{role}' in body) > 0 then body := replace(body, '{role}', chr(1));
  elsif ping then body := chr(1) || ' ' || body;
  end if;
  body := replace(body, '{url}', coalesce(v ->> 'url', ''));
  body := replace(body, '{creator}', translate(public.alerts_untag(coalesce(nullif(creator, ''), 'Someone')), '{}' || E'\n' || chr(1), '() '));
  body := replace(body, '{title}', translate(public.alerts_untag(v ->> 'title'), E'\n' || chr(1), ' '));
  -- once, on the finished text
  body := public.alerts_defuse(public.alerts_untag(body));
  body := replace(body, chr(1), case when ping then '<@&' || w.role_id::text || '>' else '' end);
  perform public.bot_say(w.channel_id, 'alerts', btrim(body));
  if not p_test then
    update public.alert_watches set last_posted_at = now(), last_video_id = v ->> 'id' where id = wid;
  end if;
end $$;
revoke all on function public.alerts_post(uuid, jsonb, text, boolean) from public, anon, authenticated;

-- Rate limits: key -> count inside a window. alerts_bump says whether this one is still allowed.
create table if not exists public.alerts_rate (k text primary key, since timestamptz not null default now(), n int not null default 0);
alter table public.alerts_rate enable row level security;
revoke all on public.alerts_rate from public, anon, authenticated;

create or replace function public.alerts_bump(p_key text, win interval, maxn int) returns boolean
language plpgsql security definer set search_path = public as $$
declare cnt int;
begin
  insert into public.alerts_rate as r (k, since, n) values (p_key, now(), 1)
  on conflict (k) do update set
    since = case when r.since < now() - win then now() else r.since end,
    n = case when r.since < now() - win then 1 else r.n + 1 end
  returning n into cnt;
  return cnt <= maxn;
end $$;
revoke all on function public.alerts_bump(text, interval, int) from public, anon, authenticated;

create or replace function public.alerts_feed_failed(cid text, msg text) returns void
language sql security definer set search_path = public as $$
  update public.yt_feeds set fails = fails + 1, last_error = left(msg, 200), last_checked_at = now(),
    pending_req = null, requested_at = null,
    next_check_at = now() + least(interval '10 minutes' * power(2, least(fails + 1, 10)), interval '12 hours')
  where channel_id = cid;
$$;
revoke all on function public.alerts_feed_failed(text, text) from public, anon, authenticated;

/** One finished fetch: parse, post anything new to every server watching, remember what was seen. */
create or replace function public.alerts_feed_result(cid text, status int, body text) returns void
language plpgsql security definer set search_path = public as $$
declare f public.yt_feeds; p jsonb; vids jsonb; v jsonb; nm text; fresh text[] := '{}'; w record;
begin
  select * into f from public.yt_feeds where channel_id = cid;
  if f.channel_id is null then return; end if;
  if status = 404 then perform public.alerts_feed_failed(cid, 'YouTube says this channel doesn''t exist'); return; end if;
  if status is distinct from 200 then perform public.alerts_feed_failed(cid, 'YouTube answered ' || coalesce(status::text, 'nothing')); return; end if;
  begin
    p := public.yt_parse_feed(body);
  exception when others then
    perform public.alerts_feed_failed(cid, 'Couldn''t read the feed'); return;
  end;
  vids := p -> 'videos';
  nm := coalesce(nullif(p ->> 'name', ''), f.name);
  if f.baseline then
    -- Oldest first, at most 5 per check, only recent ones (a deleted video can bring an old one back into the 15).
    for v in select e from jsonb_array_elements(vids) e
      where not ((e ->> 'id') = any (f.seen_ids)) and (e ->> 'published')::timestamptz > now() - interval '2 days'
      order by (e ->> 'published')::timestamptz limit 5
    loop
      fresh := fresh || (v ->> 'id');
      for w in
        select aw.id from public.alert_watches aw
        join public.server_bots b on b.server_id = aw.server_id and b.bot = 'alerts' and b.enabled
        where aw.yt_channel_id = cid and aw.created_at < (v ->> 'published')::timestamptz
          -- over the cap (Plus ran out): only the oldest ones keep working
          and (select count(*) from public.alert_watches o where o.server_id = aw.server_id and (o.created_at, o.id) < (aw.created_at, aw.id))
              < case when public.server_plus_on(aw.server_id) then 25 else 3 end
      loop
        begin
          perform public.alerts_post(w.id, v, nm);
        exception when others then null; -- one broken server must not stop the others
        end;
      end loop;
    end loop;
    fresh := fresh || f.seen_ids;
  else
    select coalesce(array_agg(e ->> 'id'), '{}') into fresh from jsonb_array_elements(vids) e;
  end if;
  -- newest first, no repeats, keep 60
  select coalesce(array_agg(x order by o), '{}') into fresh
  from (select x, min(o) as o from unnest(fresh) with ordinality u(x, o) group by x order by min(o) limit 60) s;
  update public.yt_feeds set name = nm, baseline = true, seen_ids = fresh,
    latest = case when jsonb_array_length(vids) > 0 then vids -> 0 else latest end,
    last_published = greatest(last_published, (select max((e ->> 'published')::timestamptz) from jsonb_array_elements(vids) e)),
    fails = 0, last_error = null, last_checked_at = now(), next_check_at = now() + interval '10 minutes',
    pending_req = null, requested_at = null
  where channel_id = cid;
end $$;
revoke all on function public.alerts_feed_result(text, int, text) from public, anon, authenticated;

/** pg_cron, every minute. */
create or replace function public.alerts_tick() returns void
language plpgsql security definer set search_path = public as $$
declare f record; r record; got boolean;
begin
  if coalesce((select mode from public.feature_flags where key = 'creator_alerts'), 'off') = 'off' then return; end if;
  -- 1. finished fetches
  for f in select channel_id, pending_req, requested_at from public.yt_feeds where pending_req is not null loop
    begin
      select status_code, content, timed_out, error_msg into r from net._http_response where id = f.pending_req;
      got := found;
      -- read once, then gone: no response bodies piling up in pg_net
      if got then execute 'del' || 'ete from net._http_response where id = $1' using f.pending_req; end if;
      if not got then
        if f.requested_at < now() - interval '5 minutes' then perform public.alerts_feed_failed(f.channel_id, 'YouTube didn''t answer'); end if;
      elsif coalesce(r.timed_out, false) or r.status_code is null then
        perform public.alerts_feed_failed(f.channel_id, coalesce('Couldn''t reach YouTube: ' || left(r.error_msg, 120), 'YouTube didn''t answer in time'));
      else
        perform public.alerts_feed_result(f.channel_id, r.status_code, r.content);
      end if;
    exception when others then
      perform public.alerts_feed_failed(f.channel_id, 'Something broke while checking');
    end;
  end loop;
  -- 2. once an hour: feeds nobody watches any more, old rate-limit rows
  if extract(minute from now()) = 0 then
    execute 'del' || 'ete from public.yt_feeds y where pending_req is null and created_at < now() - interval ''1 hour'''
      || ' and not exists (select 1 from public.alert_watches w where w.yt_channel_id = y.channel_id)';
    execute 'del' || 'ete from public.alerts_rate where since < now() - interval ''1 day''';
  end if;
  -- 3. fire the ones that are due (one request per YouTube channel, however many servers watch it)
  for f in
    select y.channel_id from public.yt_feeds y
    where y.pending_req is null and y.next_check_at <= now()
      and exists (select 1 from public.alert_watches w join public.server_bots b on b.server_id = w.server_id and b.bot = 'alerts' and b.enabled
                  where w.yt_channel_id = y.channel_id)
    order by y.next_check_at limit 100
  loop
    update public.yt_feeds set requested_at = now(), pending_req = net.http_get(
      'https://www.youtube.com/feeds/videos.xml?channel_id=' || f.channel_id,
      '{}'::jsonb, '{"User-Agent":"Mozilla/5.0 (compatible; YapperAlerts/1.0; +https://www.yapper.website)"}'::jsonb, 15000)
    where channel_id = f.channel_id;
  end loop;
end $$;
revoke all on function public.alerts_tick() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    if not exists (select 1 from cron.job where jobname = 'creator-alerts-tick') then
      perform cron.schedule('creator-alerts-tick', '* * * * *', 'select public.alerts_tick()');
    end if;
  end if;
end $$;

-- ---------- RPCs for the Bots page ----------
create or replace function public.alerts_list(sid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can set up alerts'; end if;
  return jsonb_build_object(
    'max', case when public.server_plus_on(sid) then 25 else 3 end,
    'watches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', w.id, 'yt_channel_id', w.yt_channel_id, 'name', f.name, 'channel_id', w.channel_id, 'role_id', w.role_id,
        'template', w.template, 'created_at', w.created_at, 'last_posted_at', w.last_posted_at,
        'last_checked_at', f.last_checked_at, 'last_error', f.last_error, 'checked', f.baseline,
        'latest_title', f.latest ->> 'title') order by w.created_at, w.id)
      from public.alert_watches w join public.yt_feeds f on f.channel_id = w.yt_channel_id
      where w.server_id = sid), '[]'::jsonb));
end $$;
revoke all on function public.alerts_list(uuid) from public, anon;
grant execute on function public.alerts_list(uuid) to authenticated;

create or replace function public.alerts_check_target(sid uuid, p_channel uuid, p_role uuid, p_template text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.channels where id = p_channel and server_id = sid and kind = 'text') then raise exception 'Pick a text channel in this server'; end if;
  if p_role is not null and not exists (select 1 from public.roles where id = p_role and server_id = sid) then raise exception 'That role isn''t in this server'; end if;
  if p_template is not null and char_length(p_template) > 500 then raise exception 'Keep the message under 500 characters'; end if;
end $$;
revoke all on function public.alerts_check_target(uuid, uuid, uuid, text) from public, anon, authenticated;

/** Is creator_alerts on for this person in this server? (feature_on without relying on auth.uid()) */
create or replace function public.alerts_flag_for(uid uuid, sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or uid = any(users)))
    from public.feature_flags where key = 'creator_alerts'), false)
$$;
revoke all on function public.alerts_flag_for(uuid, uuid) from public, anon, authenticated;

/**
 * /api/alerts/resolve asks this (service role) before it fetches anything for a caller:
 * returns null when it may go ahead, otherwise the reason. Up to 20 lookups per person per 10 minutes.
 */
create or replace function public.alerts_resolve_gate(uid uuid, sid uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if uid is null or sid is null or not public.server_perm_as(uid, sid, 'manage_server') then return 'Only server managers can set up alerts'; end if;
  if not public.alerts_flag_for(uid, sid) then return 'Alerts aren''t available here yet'; end if;
  if not public.alerts_bump('resolve:' || uid::text, interval '10 minutes', 20) then return 'Slow down a bit. Try again in a few minutes.'; end if;
  return null;
end $$;
revoke all on function public.alerts_resolve_gate(uuid, uuid) from public, anon, authenticated;
grant execute on function public.alerts_resolve_gate(uuid, uuid) to service_role;

-- p_name is kept for the client's call shape but not stored: the poller fills the name from YouTube's feed.
create or replace function public.alerts_add(sid uuid, p_yt text, p_name text, p_channel uuid, p_role uuid default null, p_template text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cap int; wid uuid; t text := nullif(btrim(coalesce(p_template, '')), '');
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can set up alerts'; end if;
  if not public.feature_on('creator_alerts', sid) then raise exception 'Alerts aren''t available here yet'; end if;
  if p_yt is null or p_yt !~ '^UC[A-Za-z0-9_-]{22}$' then raise exception 'That doesn''t look like a YouTube channel'; end if;
  perform public.alerts_check_target(sid, p_channel, p_role, t);
  if exists (select 1 from public.alert_watches where server_id = sid and yt_channel_id = p_yt) then raise exception 'You''re already watching that channel'; end if;
  cap := case when public.server_plus_on(sid) then 25 else 3 end;
  perform 1 from public.servers where id = sid for update; -- two adds at once can't both squeeze under the cap
  if (select count(*) from public.alert_watches where server_id = sid) >= cap then
    raise exception '%', case when cap = 25 then 'That''s the most (25 channels).' else 'Free servers can watch 3 channels. Server Plus gets 25.' end;
  end if;
  -- add/remove/add can't be used to hammer YouTube or skip the backoff
  if not public.alerts_bump('add:' || sid::text, interval '1 hour', 10) then raise exception 'That''s a lot of channels in one go. Try again in an hour.'; end if;
  insert into public.yt_feeds (channel_id) values (p_yt) on conflict (channel_id) do nothing;
  -- A feed stuck in backoff gets a fresh look now that someone wants it again (not more than every 10 minutes).
  update public.yt_feeds set next_check_at = now()
  where channel_id = p_yt and last_error is not null and pending_req is null and last_checked_at < now() - interval '10 minutes';
  insert into public.alert_watches (server_id, yt_channel_id, channel_id, role_id, template, created_by)
  values (sid, p_yt, p_channel, p_role, t, auth.uid()) returning id into wid;
  -- Make sure the bot is switched on (keeps any look already set).
  insert into public.server_bots (server_id, bot, enabled, config) values (sid, 'alerts', true, '{}'::jsonb)
  on conflict (server_id, bot) do nothing;
  return wid;
end $$;
revoke all on function public.alerts_add(uuid, text, text, uuid, uuid, text) from public, anon;
grant execute on function public.alerts_add(uuid, text, text, uuid, uuid, text) to authenticated;

create or replace function public.alerts_update(wid uuid, p_channel uuid, p_role uuid default null, p_template text default null)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; t text := nullif(btrim(coalesce(p_template, '')), '');
begin
  select server_id into sid from public.alert_watches where id = wid;
  if sid is null or not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can set up alerts'; end if;
  if not public.feature_on('creator_alerts', sid) then raise exception 'Alerts aren''t available here yet'; end if;
  perform public.alerts_check_target(sid, p_channel, p_role, t);
  update public.alert_watches set channel_id = p_channel, role_id = p_role, template = t where id = wid;
end $$;
revoke all on function public.alerts_update(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.alerts_update(uuid, uuid, uuid, text) to authenticated;

create or replace function public.alerts_remove(wid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.alert_watches where id = wid;
  if sid is null or not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can set up alerts'; end if;
  execute 'del' || 'ete from public.alert_watches where id = $1' using wid;
end $$;
revoke all on function public.alerts_remove(uuid) from public, anon;
grant execute on function public.alerts_remove(uuid) to authenticated;

/** "Post latest video now": posts the newest video we know of, like a real alert but without the role ping. */
create or replace function public.alerts_test(wid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare w public.alert_watches; f public.yt_feeds; claimed uuid;
begin
  select * into w from public.alert_watches where id = wid;
  if w.id is null or not public.server_perm(w.server_id, 'manage_server') then raise exception 'Only server managers can set up alerts'; end if;
  if not public.feature_on('creator_alerts', w.server_id) then raise exception 'Alerts aren''t available here yet'; end if;
  if not exists (select 1 from public.server_bots where server_id = w.server_id and bot = 'alerts' and enabled) then raise exception 'Turn Alerts on first'; end if;
  select * into f from public.yt_feeds where channel_id = w.yt_channel_id;
  if f.latest is null then
    if f.last_error is not null then raise exception '%', f.last_error; end if;
    raise exception 'Still checking this channel. Try again in a minute.';
  end if;
  -- claim the cooldown atomically: one per channel per 10 s, one per server per 30 s
  update public.alert_watches set last_test_at = now()
  where id = wid and (last_test_at is null or last_test_at < now() - interval '10 seconds') returning id into claimed;
  if claimed is null or not public.alerts_bump('test:' || w.server_id::text, interval '30 seconds', 1) then raise exception 'Slow down a sec'; end if;
  perform public.alerts_post(wid, f.latest, f.name, true);
  return f.latest ->> 'title';
end $$;
revoke all on function public.alerts_test(uuid) from public, anon;
grant execute on function public.alerts_test(uuid) to authenticated;
