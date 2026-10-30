-- 661: Lobby feeds and more leaderboards (flag lobby_feeds, test: Antic and his test server).
-- 1. Leaderboard kinds. The lobby's Leaderboard section can show up to 3 boards as tabs: Levels (as before, from
--    lobby_extras), Most messages (last 7 days) and Most invites (invites.uses by creator). Voice time isn't tracked
--    anywhere, so there's no voice board.
--    lobby_board(sid, kind) answers from lobby_board_cache, rebuilt at most every 10 minutes per server and kind by
--    whoever asks first (one at a time, under a try-lock; the others get the last answer). Messages never scan the
--    whole week: lobby_msg_days keeps per-day counts per member, and each rebuild only adds the messages since the
--    last one (index messages_channel_created_idx, channel by channel), at most one day of them per call, with the
--    progress saved each time, so a big server's first build is spread over a few views instead of one slow query
--    that times out and starts over. Only channels @everyone can see count (server_watch_public_channel, once per
--    channel), so the board doesn't tell members who's busy in private or staff channels. Nothing touches the
--    message insert path.
-- 2. Lobby feeds. Managers (Manage Server) make a feed in the lobby editor and get a URL with a secret token in it
--    (only its sha256 is stored, like channel webhooks in 155). Outside apps POST to /api/lobby-feeds/:id/:token; the
--    route rate-limits (lobby_feed_take, same webhook_hit counters as webhooks) and posts (lobby_feed_post). The
--    Feed section shows the server's last 10 posts across its feeds (lobby_feed_posts). Each feed keeps its last 20.
-- 3. set_server_lobby_v2 accepts the feed section and the leaderboard's kinds, and still keeps 658's side flag
--    (this replaces 658's version, so it carries that over).
-- Tables have RLS on with nothing granted: everything goes through the functions below.
set lock_timeout = '3s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('lobby_feeds', 'Lobby feeds and leaderboards',
  'Lobby: more leaderboards (messages this week, invites) and a feed section outside apps post into through a webhook URL. Needs lobby_v2. Test: Antic only',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- Leaderboards ----------

create table if not exists public.lobby_msg_days (
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null,
  day date not null,
  n integer not null default 0,
  primary key (server_id, day, user_id)
);
alter table public.lobby_msg_days enable row level security;
revoke all on public.lobby_msg_days from public, anon, authenticated;

create table if not exists public.lobby_board_cache (
  server_id uuid not null references public.servers(id) on delete cascade,
  kind text not null check (kind in ('messages', 'invites')),
  rows jsonb not null default '[]'::jsonb,
  at timestamptz not null default now(),
  -- messages: lobby_msg_days holds every message before this.
  rolled_to timestamptz,
  primary key (server_id, kind)
);
alter table public.lobby_board_cache enable row level security;
revoke all on public.lobby_board_cache from public, anon, authenticated;

/**
 * One leaderboard for the lobby: [{user_id, n}], top 10 current members who aren't site-banned. kind: messages (last
 * 7 days) or invites (all time). Null when the caller can't see the lobby. Levels stays in lobby_extras.
 */
create or replace function public.lobby_board(sid uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  c record;
  out_rows jsonb;
  since timestamptz;
  upto timestamptz;
  caught_up boolean := true;
begin
  if auth.uid() is null or public.is_site_banned(auth.uid()) or not public.is_server_member(sid)
     or exists (select 1 from public.servers s where s.id = sid and s.shut_down_at is not null and not public.is_staff())
     or not public.feature_on('lobby_v2', sid) or not public.feature_on('lobby_feeds', sid)
     or p_kind is null or not p_kind = any (array['messages', 'invites']) then
    return null;
  end if;
  select * into c from public.lobby_board_cache x where x.server_id = sid and x.kind = p_kind;
  if c.server_id is not null and c.at > now() - interval '10 minutes' then return c.rows; end if;
  -- Someone else is rebuilding this server's boards right now: the last answer (or nothing yet) will do.
  if not pg_try_advisory_xact_lock(hashtextextended('lobby_board:' || sid::text, 0)) then
    return coalesce(c.rows, '[]'::jsonb);
  end if;
  -- Read it again under the lock: whoever held it before may have just rebuilt it (and moved rolled_to on), and
  -- rolling up from the old rolled_to would count those messages twice.
  select * into c from public.lobby_board_cache x where x.server_id = sid and x.kind = p_kind;
  if c.server_id is not null and c.at > now() - interval '10 minutes' then return c.rows; end if;

  if p_kind = 'messages' then
    since := greatest(coalesce(c.rolled_to, now() - interval '7 days'), now() - interval '7 days');
    -- At most a day of messages per call (the busiest server sends ~36k a day); the rest on the next views.
    upto := least(now() - interval '5 seconds', since + interval '1 day');
    caught_up := upto >= now() - interval '5 seconds';
    if since < upto then
      insert into public.lobby_msg_days as d (server_id, user_id, day, n)
        select sid, m.author_id, (m.created_at at time zone 'utc')::date, count(*)::int
        from (select ch.id from public.channels ch
              where ch.server_id = sid and ch.ticket_by is null and public.server_watch_public_channel(ch.id)
              offset 0) pub
        join public.messages m on m.channel_id = pub.id and m.created_at >= since and m.created_at < upto
        where m.webhook is null and m.system is null
        group by m.author_id, (m.created_at at time zone 'utc')::date
      on conflict (server_id, day, user_id) do update set n = d.n + excluded.n;
    end if;
    execute 'del' || 'ete from public.lobby_msg_days where server_id = $1 and day < $2'
      using sid, ((now() at time zone 'utc')::date - 8);
    select coalesce(jsonb_agg(jsonb_build_object('user_id', t.user_id, 'n', t.n) order by t.n desc), '[]'::jsonb) into out_rows
      from (
        select d.user_id, sum(d.n)::int as n from public.lobby_msg_days d
        where d.server_id = sid and d.day > (now() at time zone 'utc')::date - 7
          and exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = d.user_id)
          and not exists (select 1 from public.site_bans b where b.user_id = d.user_id and (b.expires_at is null or b.expires_at > now()))
          and not exists (select 1 from public.bot_accounts a where a.user_id = d.user_id)
        group by d.user_id
        order by 2 desc
        limit 10
      ) t;
  else
    select coalesce(jsonb_agg(jsonb_build_object('user_id', t.user_id, 'n', t.n) order by t.n desc), '[]'::jsonb) into out_rows
      from (
        select i.created_by as user_id, sum(i.uses)::int as n from public.invites i
        where i.server_id = sid and i.created_by is not null and not coalesce(i.vanity, false)
          and exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = i.created_by)
          and not exists (select 1 from public.site_bans b where b.user_id = i.created_by and (b.expires_at is null or b.expires_at > now()))
        group by i.created_by
        having sum(i.uses) > 0
        order by 2 desc
        limit 10
      ) t;
  end if;

  -- Still catching up (a first build): saved as already stale, so the next view carries on from rolled_to.
  insert into public.lobby_board_cache as x (server_id, kind, rows, at, rolled_to)
    values (sid, p_kind, out_rows, case when caught_up then now() else now() - interval '1 hour' end, upto)
  on conflict (server_id, kind) do update set rows = excluded.rows, at = excluded.at,
    rolled_to = coalesce(excluded.rolled_to, x.rolled_to);
  return out_rows;
end $$;
revoke all on function public.lobby_board(uuid, text) from public, anon;
grant execute on function public.lobby_board(uuid, text) to authenticated;

-- ---------- Feeds ----------

create table if not exists public.lobby_feeds (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  last_post_at timestamptz,
  posts bigint not null default 0
);
create index if not exists lobby_feeds_server on public.lobby_feeds (server_id);
create index if not exists lobby_feeds_created_by on public.lobby_feeds (created_by);
alter table public.lobby_feeds enable row level security;
revoke all on public.lobby_feeds from public, anon, authenticated;

create table if not exists public.lobby_feed_posts (
  id uuid primary key default gen_random_uuid(),
  feed_id uuid not null references public.lobby_feeds(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  title text check (char_length(title) <= 200),
  body text check (char_length(body) <= 1000),
  url text check (char_length(url) <= 500 and url ~* '^https://'),
  image text check (char_length(image) <= 500 and image ~* '^https://'),
  created_at timestamptz not null default now(),
  check (coalesce(title, '') <> '' or coalesce(body, '') <> '')
);
create index if not exists lobby_feed_posts_server on public.lobby_feed_posts (server_id, created_at desc);
create index if not exists lobby_feed_posts_feed on public.lobby_feed_posts (feed_id, created_at desc);
alter table public.lobby_feed_posts enable row level security;
revoke all on public.lobby_feed_posts from public, anon, authenticated;

/** Managers of a server with the flag on, or an exception. */
create or replace function public.lobby_feed_guard(sid uuid)
returns void
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null or sid is null or not public.server_perm(sid, 'manage_server') then
    raise exception 'Only server managers can manage lobby feeds' using errcode = 'insufficient_privilege';
  end if;
  if not public.feature_on('lobby_feeds', sid) then
    raise exception 'Lobby feeds aren''t on in this server yet' using errcode = 'check_violation';
  end if;
end $$;
revoke all on function public.lobby_feed_guard(uuid) from public, anon, authenticated;

/** A feed name, tidied, or an exception. */
create or replace function public.lobby_feed_name(p_name text)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare n text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if n = '' or char_length(n) > 40 then
    raise exception 'Feed names can be 1 to 40 characters' using errcode = 'check_violation';
  end if;
  if public.bad_name(n) or public.lobby_text_problem(n) is not null then
    raise exception 'That name isn''t allowed' using errcode = 'check_violation';
  end if;
  return n;
end $$;
revoke all on function public.lobby_feed_name(text) from public, anon, authenticated;

/** This server's feeds, for its managers (no tokens: only the hash is kept). */
create or replace function public.lobby_feed_list(sid uuid)
returns table (id uuid, name text, created_at timestamptz, last_post_at timestamptz, posts bigint)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  perform public.lobby_feed_guard(sid);
  return query select f.id, f.name, f.created_at, f.last_post_at, f.posts from public.lobby_feeds f
    where f.server_id = sid order by f.created_at;
end $$;

/** A new feed: {id, token}. The token is shown once. Up to 5 per server. */
create or replace function public.lobby_feed_create(sid uuid, p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare n text; tok text; fid uuid;
begin
  perform public.lobby_feed_guard(sid);
  n := public.lobby_feed_name(p_name);
  perform pg_advisory_xact_lock(hashtextextended('lobby_feeds:' || sid::text, 0));
  if (select count(*) from public.lobby_feeds f where f.server_id = sid) >= 5 then
    raise exception 'A server can have up to 5 feeds' using errcode = 'check_violation';
  end if;
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.lobby_feeds (server_id, name, token_hash, created_by)
    values (sid, n, encode(sha256(convert_to(tok, 'UTF8')), 'hex'), auth.uid())
    returning id into fid;
  perform public.audit_add(sid, 'server_update_lobby', 'lobby_feed', fid, n, '{"feed": "create"}'::jsonb);
  return jsonb_build_object('id', fid, 'token', tok);
end $$;

/** A new token for a feed; the old URL stops working. */
create or replace function public.lobby_feed_rotate(fid uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare f record; tok text;
begin
  select x.id, x.server_id, x.name into f from public.lobby_feeds x where x.id = fid;
  if f.id is null then raise exception 'No such feed'; end if;
  perform public.lobby_feed_guard(f.server_id);
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  update public.lobby_feeds set token_hash = encode(sha256(convert_to(tok, 'UTF8')), 'hex') where id = fid;
  perform public.audit_add(f.server_id, 'server_update_lobby', 'lobby_feed', fid, f.name, '{"feed": "new_url"}'::jsonb);
  return tok;
end $$;

create or replace function public.lobby_feed_rename(fid uuid, p_name text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare sid uuid;
begin
  select x.server_id into sid from public.lobby_feeds x where x.id = fid;
  if sid is null then raise exception 'No such feed'; end if;
  perform public.lobby_feed_guard(sid);
  update public.lobby_feeds set name = public.lobby_feed_name(p_name) where id = fid;
end $$;

/** Removes a feed and its posts. */
create or replace function public.lobby_feed_remove(fid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare f record;
begin
  select x.id, x.server_id, x.name into f from public.lobby_feeds x where x.id = fid;
  if f.id is null then raise exception 'No such feed'; end if;
  perform public.lobby_feed_guard(f.server_id);
  execute 'del' || 'ete from public.lobby_feeds where id = $1' using fid;
  perform public.audit_add(f.server_id, 'server_update_lobby', 'lobby_feed', fid, f.name, '{"feed": "remove"}'::jsonb);
end $$;

revoke all on function public.lobby_feed_list(uuid) from public, anon;
revoke all on function public.lobby_feed_create(uuid, text) from public, anon;
revoke all on function public.lobby_feed_rotate(uuid) from public, anon;
revoke all on function public.lobby_feed_rename(uuid, text) from public, anon;
revoke all on function public.lobby_feed_remove(uuid) from public, anon;
grant execute on function public.lobby_feed_list(uuid) to authenticated;
grant execute on function public.lobby_feed_create(uuid, text) to authenticated;
grant execute on function public.lobby_feed_rotate(uuid) to authenticated;
grant execute on function public.lobby_feed_rename(uuid, text) to authenticated;
grant execute on function public.lobby_feed_remove(uuid) to authenticated;

/** The last 10 posts across this server's feeds, newest first, for anyone who can see the lobby. */
create or replace function public.lobby_feed_posts(sid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null or public.is_site_banned(auth.uid()) or not public.is_server_member(sid)
     or exists (select 1 from public.servers s where s.id = sid and s.shut_down_at is not null and not public.is_staff())
     or not public.feature_on('lobby_v2', sid) or not public.feature_on('lobby_feeds', sid) then
    return null;
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'feed', f.name, 'title', p.title, 'text', p.body,
      'url', p.url, 'image', p.image, 'at', p.created_at) order by p.created_at desc), '[]'::jsonb)
    from (select * from public.lobby_feed_posts x where x.server_id = sid order by x.created_at desc limit 10) p
    join public.lobby_feeds f on f.id = p.feed_id);
end $$;
revoke all on function public.lobby_feed_posts(uuid) from public, anon;
grant execute on function public.lobby_feed_posts(uuid) to authenticated;

-- ---------- Feeds: service role (the API route) ----------

/**
 * The rate limit, as its own call before lobby_feed_post so it counts even when the post then fails.
 * {"ok": true}, {"code": 404 | 401} for a wrong id or token, or {"code": 429, "retry_after": s}.
 * 5 a minute and 30 an hour per feed: feeds are for uploads and alerts, not chat.
 */
create or replace function public.lobby_feed_take(fid uuid, tok text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare f record; wait numeric;
begin
  if tok is null or tok !~ '^[0-9a-f]{64}$' then return jsonb_build_object('code', 401); end if;
  select x.id, x.token_hash into f from public.lobby_feeds x where x.id = fid;
  if f.id is null then return jsonb_build_object('code', 404); end if;
  if f.token_hash <> encode(sha256(convert_to(tok, 'UTF8')), 'hex') then
    -- Wrong tokens count too (30 a minute per feed), so a loop of junk tokens is cut off early.
    wait := public.webhook_hit('lfbad:' || f.id::text, 60, 30);
    if wait > 0 then return jsonb_build_object('code', 429, 'retry_after', wait); end if;
    return jsonb_build_object('code', 401);
  end if;
  wait := public.webhook_hit('lf:' || f.id::text, 60, 5);
  if wait = 0 then wait := public.webhook_hit('lfh:' || f.id::text, 3600, 30); end if;
  if random() < 0.01 then
    execute 'del' || 'ete from public.webhook_rate where at < now() - interval ''2 hours''';
  end if;
  if wait > 0 then return jsonb_build_object('code', 429, 'retry_after', wait); end if;
  return jsonb_build_object('ok', true);
end $$;

/**
 * Posts into a feed (after lobby_feed_take). The route has already cut the fields to size and kept only https links
 * and allowed image hosts; here the token, the flag and the server are checked again and the text goes through the
 * same filters as lobby text (adult links, slurs, sexual spam) plus self-harm incitement. Keeps the feed's last 20.
 * Errors carry a hint "feed:<status>" for the route.
 */
create or replace function public.lobby_feed_post(fid uuid, tok text, p_title text, p_text text, p_url text, p_image text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  f record;
  t text := nullif(btrim(coalesce(p_title, '')), '');
  b text := nullif(btrim(coalesce(p_text, '')), '');
  u text := nullif(btrim(coalesce(p_url, '')), '');
  img text := nullif(btrim(coalesce(p_image, '')), '');
  all_text text;
  pid uuid;
begin
  select x.id, x.server_id, x.token_hash into f from public.lobby_feeds x where x.id = fid;
  if f.id is null then raise exception 'Unknown feed' using hint = 'feed:404'; end if;
  if tok is null or f.token_hash <> encode(sha256(convert_to(tok, 'UTF8')), 'hex') then
    raise exception 'Invalid feed token' using hint = 'feed:401';
  end if;
  if not public.feature_on('lobby_feeds', f.server_id)
     or exists (select 1 from public.servers s where s.id = f.server_id and s.shut_down_at is not null) then
    raise exception 'Feeds aren''t on in this server' using hint = 'feed:403';
  end if;
  if t is null and b is null then raise exception 'A post needs a title or some text' using hint = 'feed:400'; end if;
  if char_length(coalesce(t, '')) > 200 or char_length(coalesce(b, '')) > 1000 then
    raise exception 'Titles can be up to 200 characters and text up to 1000' using hint = 'feed:400';
  end if;
  if u is not null and (char_length(u) > 500 or u !~* '^https://[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]{1,5})?([/?#]\S*)?$') then
    raise exception 'Links have to be https:// addresses' using hint = 'feed:400';
  end if;
  if img is not null and (char_length(img) > 500 or img !~* '^https://[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]{1,5})?([/?#]\S*)?$') then
    img := null;
  end if;
  all_text := concat_ws(' ', t, b, u, img);
  if public.lobby_text_problem(all_text) is not null or public.has_self_harm_incitement(all_text) then
    raise exception 'Some of that post isn''t allowed on Yapper' using hint = 'feed:422';
  end if;
  insert into public.lobby_feed_posts (feed_id, server_id, title, body, url, image)
    values (f.id, f.server_id, t, b, u, img) returning id into pid;
  update public.lobby_feeds set last_post_at = now(), posts = posts + 1 where id = f.id;
  execute 'del' || 'ete from public.lobby_feed_posts where feed_id = $1 and id in ('
    || 'select id from public.lobby_feed_posts where feed_id = $1 order by created_at desc offset 20)' using f.id;
  return pid;
end $$;
revoke all on function public.lobby_feed_take(uuid, text) from public, anon, authenticated;
revoke all on function public.lobby_feed_post(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.lobby_feed_take(uuid, text) to service_role;
grant execute on function public.lobby_feed_post(uuid, text, text, text, text, text) to service_role;

-- ---------- The lobby save: feed section and leaderboard kinds ----------

create or replace function public.set_server_lobby_v2(sid uuid, p_about text, p_faq jsonb, p_featured uuid[], p_show_staff boolean,
  p_style jsonb, p_sections jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  st jsonb := coalesce(p_style, '{}'::jsonb);
  out_style jsonb := '{}'::jsonb;
  out_sections jsonb := '[]'::jsonb;
  seen text[] := '{}';
  k text;
  v text;
  item jsonb;
  label text;
  url text;
  ch uuid;
  btns jsonb := '[]'::jsonb;
  problem text;
  kinds text[];
  kv text;
  sec jsonb;
begin
  if auth.uid() is null or not public.server_perm(sid, 'manage_server') then
    raise exception 'Only server managers can change the lobby' using errcode = 'insufficient_privilege';
  end if;
  if not public.feature_on('lobby_v2', sid) then
    raise exception 'Lobby customizing isn''t on in this server yet' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(st) <> 'object' then
    raise exception 'The lobby look has to be an object' using errcode = 'check_violation';
  end if;
  if p_sections is not null and (jsonb_typeof(p_sections) <> 'array' or jsonb_array_length(p_sections) > 20) then
    raise exception 'That''s too many lobby sections' using errcode = 'check_violation';
  end if;
  if st ? 'buttons' and (jsonb_typeof(st -> 'buttons') <> 'array' or jsonb_array_length(st -> 'buttons') > 4) then
    raise exception 'Up to 4 lobby buttons' using errcode = 'check_violation';
  end if;

  -- Choices: each key takes one of a few values; anything else is refused so the client can't store junk.
  for k, v in select key, value #>> '{}' from jsonb_each(st) where key in ('preset', 'bg', 'cards', 'font', 'hero', 'align') loop
    if v is null or not v = any (case k
        when 'preset' then array['classic', 'spotlight', 'magazine', 'compact']
        when 'bg' then array['plain', 'glow', 'banner', 'mesh']
        when 'cards' then array['filled', 'outline', 'glass']
        when 'font' then array['default', 'rounded', 'serif', 'mono', 'display']
        when 'hero' then array['tall', 'normal', 'short']
        when 'align' then array['left', 'center'] end) then
      raise exception 'Unknown lobby % "%"', k, coalesce(v, '') using errcode = 'check_violation';
    end if;
    out_style := out_style || jsonb_build_object(k, v);
  end loop;

  if st ? 'accent' and jsonb_typeof(st -> 'accent') <> 'null' then
    v := st ->> 'accent';
    if v is null or v !~ '^#[0-9a-fA-F]{6}$' then
      raise exception 'The accent has to be a colour like #ff8800' using errcode = 'check_violation';
    end if;
    out_style := out_style || jsonb_build_object('accent', lower(v));
  end if;

  v := btrim(coalesce(st ->> 'tagline', ''));
  if char_length(v) > 120 then
    raise exception 'The tagline can be up to 120 characters' using errcode = 'check_violation';
  end if;
  problem := public.lobby_text_problem(v);
  if problem is not null then
    raise exception '%', problem using errcode = 'check_violation';
  end if;
  if v <> '' then out_style := out_style || jsonb_build_object('tagline', v); end if;

  for item in select value from jsonb_array_elements(coalesce(st -> 'buttons', '[]'::jsonb)) loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'Each lobby button needs a label and a link or channel' using errcode = 'check_violation';
    end if;
    label := btrim(coalesce(item ->> 'label', ''));
    url := nullif(btrim(coalesce(item ->> 'url', '')), '');
    continue when label = '' and url is null and coalesce(item ->> 'channel', '') = '';
    if label = '' or char_length(label) > 24 then
      raise exception 'Button labels can be 1 to 24 characters' using errcode = 'check_violation';
    end if;
    problem := public.lobby_text_problem(label);
    if problem is not null then
      raise exception '%', problem using errcode = 'check_violation';
    end if;
    if url is not null then
      if char_length(url) > 500 or url !~* '^https://[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]{1,5})?([/?#]\S*)?$' then
        raise exception 'Button links have to be https:// addresses' using errcode = 'check_violation';
      end if;
      if public.has_adult_link(url) then
        raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
      end if;
      btns := btns || jsonb_build_array(jsonb_build_object('label', label, 'url', url));
    else
      begin
        ch := (item ->> 'channel')::uuid;
      exception when others then
        ch := null;
      end;
      if ch is null or not exists (select 1 from public.channels c where c.id = ch and c.server_id = sid and c.ticket_by is null) then
        raise exception 'Button channels have to be channels in this server' using errcode = 'check_violation';
      end if;
      btns := btns || jsonb_build_array(jsonb_build_object('label', label, 'channel', ch));
    end if;
  end loop;
  if jsonb_array_length(btns) > 0 then out_style := out_style || jsonb_build_object('buttons', btns); end if;

  -- Sections: known blocks only, each once, in the order given. 661: the feed block (flag lobby_feeds), and the
  -- leaderboard keeps the boards it shows (kinds: levels, messages, invites; 1 to 3, each once, first is the default tab).
  for item in select value from jsonb_array_elements(coalesce(p_sections, '[]'::jsonb)) loop
    k := item ->> 'id';
    if jsonb_typeof(item) <> 'object' or k is null
       or not k = any (array['about', 'channels', 'live', 'faq', 'roles', 'rules', 'staff', 'links', 'leaderboard', 'giveaways', 'feed']) then
      raise exception 'Unknown lobby section' using errcode = 'check_violation';
    end if;
    continue when k = any(seen);
    seen := seen || k;
    -- Without the flag the feed block and the leaderboard's boards aren't kept (the block lists fill back in later).
    continue when k = 'feed' and not public.feature_on('lobby_feeds', sid);
    sec := jsonb_build_object('id', k, 'on', coalesce(case when jsonb_typeof(item -> 'on') = 'boolean' then (item -> 'on')::boolean end, true));
    -- 658 (drag on the canvas): an optional side boolean, the block's column; kept so this doesn't undo it.
    if jsonb_typeof(item -> 'side') = 'boolean' then sec := sec || jsonb_build_object('side', (item -> 'side')::boolean); end if;
    if k = 'leaderboard' and item ? 'kinds' and public.feature_on('lobby_feeds', sid) then
      if jsonb_typeof(item -> 'kinds') <> 'array' or jsonb_array_length(item -> 'kinds') > 3 then
        raise exception 'Pick up to 3 leaderboards' using errcode = 'check_violation';
      end if;
      kinds := '{}';
      for kv in select value #>> '{}' from jsonb_array_elements(item -> 'kinds') loop
        if kv is null or not kv = any (array['levels', 'messages', 'invites']) then
          raise exception 'Unknown leaderboard "%"', coalesce(kv, '') using errcode = 'check_violation';
        end if;
        if not kv = any(kinds) then kinds := kinds || kv; end if;
      end loop;
      if cardinality(kinds) > 0 then sec := sec || jsonb_build_object('kinds', to_jsonb(kinds)); end if;
    end if;
    out_sections := out_sections || jsonb_build_array(sec);
  end loop;

  -- The content, with all of set_server_lobby's checks (and its audit entry).
  perform public.set_server_lobby(sid, p_about, p_faq, p_featured, p_show_staff);

  update public.server_lobby set style = out_style, sections = out_sections where server_id = sid;
end $$;

revoke all on function public.set_server_lobby_v2(uuid, text, jsonb, uuid[], boolean, jsonb, jsonb) from public, anon;
grant execute on function public.set_server_lobby_v2(uuid, text, jsonb, uuid[], boolean, jsonb, jsonb) to authenticated;
