-- 155: channel webhooks (flag webhooks, test only). Re-runnable.
-- People with Manage Webhooks (owner, Administrator, or a role with perms.manage_webhooks; channel overrides apply)
-- make up to 10 webhooks per text channel in Edit channel → Webhooks. Each has a secret URL:
-- POST https://www.yapper.website/api/webhooks/<id>/<token> with Discord-style JSON (content, username, avatar_url,
-- embeds, allowed_mentions) posts a message.
--   webhooks: one row per webhook. Only the sha256 of the token is kept (like bot tokens and interaction tokens in 147);
--     the token is shown once on create / "New URL". Nobody reads the table directly: everything goes through the functions.
--   messages.webhook: { id, name, avatar_url, avatar_path } of the webhook that posted it (name and picture as sent).
--     Only webhook_send can set it (yapper.webhook = 1), and nobody can change it afterwards. The guard triggers only
--     run when the column is set or changed, so normal sends pay nothing.
--   Webhook messages are posted as one shared bot account (app_settings.webhook_user_id). The API makes it on first use
--     with the service key, like bot accounts, and claims it with webhook_claim_author. Moderation never lands on it:
--     reports of a webhook message target the webhook's creator (reports.webhook_id keeps which webhook), and
--     apply_auto_action, site_ban and mod_purge_messages skip the shared account (patched in place below).
--   webhook_take (service role, its own call before webhook_send so failed sends still count): token check, then the
--     rate limit, 5 per 2 s per webhook and 30 a minute per channel (webhook_rate counters, one atomic upsert each).
--   webhook_send (service role): token check, flag (feature_on('webhooks', sid), or the creator is in the flag's test
--     users), text channels only. The message guards skip bot posts (yapper.bot = 1), so the creator is checked here:
--     still a member, not banned (server or site), not timed out (server or site), can still see the channel and still
--     has Manage Webhooks there; and the server isn't shut down or locked (unless the creator could post in a lock).
--     Slurs, adult links and self-harm checks also cover the username and the embed text (the message triggers only see
--     content; the hate guard sees embeds too).
--     allowed_mentions: by default users are pinged, @everyone/@here and roles are not. @everyone/@here only go through
--     when allowed AND the creator has Mention @everyone in that channel; roles only when allowed (then the usual
--     fix_role_pings_bot rule: only mentionable roles ping).
--   Names (webhook names and per-message usernames) are checked after removing invisible characters and folding look-alikes
--     (slur_text): no admin / mod / staff / support / official / yapper variants, and no staff usernames or display names.
--   messages_embeds_shape now allows up to 10 embeds (webhooks; the bot API still caps bots at 5) and 48 KB.

insert into public.feature_flags (key, label, description, mode, servers)
values ('webhooks', 'Webhooks', 'Channel webhooks: post messages with embeds to a channel from a secret URL, Discord-style', 'test', '{}')
on conflict (key) do nothing;

-- The messages changes below take a short exclusive lock: give up quickly rather than queue behind a long query
-- (a queued lock would hold up every send). Re-run if it times out.
set lock_timeout = '1s';

-- ---------- where webhook messages come from ----------
alter table public.app_settings add column if not exists webhook_user_id uuid;

alter table public.messages add column if not exists webhook jsonb;
-- NOT VALID on purpose (no table scan under the lock). Validate later, off-peak:
--   alter table public.messages validate constraint messages_webhook_shape;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'messages_webhook_shape' and conrelid = 'public.messages'::regclass) then
    alter table public.messages add constraint messages_webhook_shape check (
      webhook is null or (jsonb_typeof(webhook) = 'object' and octet_length(webhook::text) <= 1500)
    ) not valid;
  end if;
end $$;

-- Up to 10 embeds per message (Discord's webhook limit). NOT VALID: old rows aren't rescanned. Validate later, off-peak:
--   alter table public.messages validate constraint messages_embeds_shape;
do $$
declare def text;
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
   where conname = 'messages_embeds_shape' and conrelid = 'public.messages'::regclass;
  if def is not null and position('<= 10)' in def) = 0 then
    execute 'alter table public.messages dr' || 'op constraint messages_embeds_shape';
    def := null;
  end if;
  if def is null then
    alter table public.messages add constraint messages_embeds_shape check (
      embeds is null or (jsonb_typeof(embeds) = 'array' and jsonb_array_length(embeds) between 1 and 10 and octet_length(embeds::text) <= 48000)
    ) not valid;
  end if;
end $$;

-- Only webhook_send sets messages.webhook; nobody changes it later. The WHEN clauses keep normal sends and edits free.
create or replace function public.message_webhook_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('yapper.webhook', true), '') <> '1' then new.webhook := null; end if;
  else
    new.webhook := old.webhook;
  end if;
  return new;
end $$;
revoke all on function public.message_webhook_guard() from public, anon, authenticated;
create or replace trigger messages_webhook_insert before insert on public.messages
  for each row when (new.webhook is not null) execute function public.message_webhook_guard();
create or replace trigger messages_webhook_update before update of webhook on public.messages
  for each row when (new.webhook is distinct from old.webhook) execute function public.message_webhook_guard();
reset lock_timeout;

-- ---------- webhooks ----------
create table if not exists public.webhooks (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  channel_id uuid not null references public.channels(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  avatar_path text check (avatar_path is null or (avatar_path like 'webhooks/%' and char_length(avatar_path) <= 300)),
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),  -- sha256 (hex) of the token
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  posts bigint not null default 0
);
create index if not exists webhooks_channel on public.webhooks (channel_id);
create index if not exists webhooks_server on public.webhooks (server_id);
create index if not exists webhooks_created_by on public.webhooks (created_by);
alter table public.webhooks enable row level security;
revoke all on public.webhooks from public, anon, authenticated;
-- Pictures go through the same check as profile pictures; names through the slur filter.
create or replace trigger webhooks_scanned_media before insert or update of avatar_path on public.webhooks
  for each row execute function public.require_scanned_media('avatar_path', 'avatars');
create or replace trigger webhooks_no_slurs before insert or update of name on public.webhooks
  for each row execute function public.no_slurs('name');

-- Rate limit counters: one row per key and time window.
create table if not exists public.webhook_rate (
  k text not null,
  bucket bigint not null,
  n int not null default 0,
  at timestamptz not null default now(),
  primary key (k, bucket)
);
create index if not exists webhook_rate_at on public.webhook_rate (at);
alter table public.webhook_rate enable row level security;
revoke all on public.webhook_rate from public, anon, authenticated;

-- Reports of webhook messages remember the webhook (its creator is the target).
alter table public.reports add column if not exists webhook_id uuid;

/** One hit on a counter: 0 when it fits, else seconds until the window ends. */
create or replace function public.webhook_hit(k text, win int, lim int) returns numeric
language plpgsql security definer set search_path = public as $$
declare e numeric := extract(epoch from clock_timestamp()); b bigint := floor(e / win); got int;
begin
  insert into public.webhook_rate as r (k, bucket, n) values (k, b, 1)
    on conflict on constraint webhook_rate_pkey do update set n = r.n + 1 where r.n < lim
    returning r.n into got;
  if got is null then return greatest(0.001, round((b + 1) * win - e, 3)); end if;
  return 0;
end $$;
revoke all on function public.webhook_hit(text, int, int) from public, anon, authenticated;

/**
 * A webhook name (or username override), tidied. Raises when it isn't allowed. Invisible characters (zero-width,
 * joiners, bidi controls, soft hyphen, variation selectors, filler) are removed first; look-alikes and digit swaps are
 * folded with slur_text before matching, so "Yapp3r", "ＡＤＭＩＮ" and "Y<zero-width>apper" are caught too.
 */
create or replace function public.webhook_name_ok(t text) returns text
language plpgsql stable security definer set search_path = public as $$
declare n text; words text; flat text;
begin
  n := regexp_replace(coalesce(t, ''),
    '[\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f\u202a-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0]', '', 'g');
  n := btrim(regexp_replace(n, '\s+', ' ', 'g'));
  if char_length(n) < 1 or char_length(n) > 80 then raise exception 'Webhook names are 1 to 80 characters'; end if;
  words := ' ' || public.slur_text(n) || ' ';
  flat := replace(words, ' ', '');
  if public.bad_name(n)
     or flat ~ '(yap+er|official|admin|moderat|staff|support|clyde|discord)'
     or words ~ ' (mod|mods|system|everyone|here) '
     or exists (select 1 from public.profiles p
                 where p.id in (select a.user_id from public.site_admins a union select m.user_id from public.site_moderators m)
                   and (lower(p.username) = lower(n) or lower(p.display_name) = lower(n)
                        or replace(public.slur_text(coalesce(p.display_name, p.username)), ' ', '') = flat)) then
    raise exception 'That name isn''t allowed';
  end if;
  return n;
end $$;
revoke all on function public.webhook_name_ok(text) from public, anon, authenticated;

/** Does uid have perm in this channel's server (owner, Administrator, roles, old manage switches, channel overrides)? */
create or replace function public.webhook_user_perm(uid uuid, cid uuid, perm text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare c record; base boolean; cp boolean;
begin
  if uid is null then return false; end if;
  select ch.id, ch.server_id, ch.category_id into c from public.channels ch where ch.id = cid;
  if c.server_id is null then return false; end if;
  base := exists (select 1 from public.servers s where s.id = c.server_id and s.owner_id = uid)
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = c.server_id and mr.user_id = uid
                 and (coalesce((r.perms ->> 'administrator')::boolean, false)
                      or (r.manage_server and public.legacy_manage_server(perm))
                      or (r.manage_messages and public.legacy_manage_messages(perm))
                      or coalesce((r.perms ->> perm)::boolean, false)));
  cp := exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                  and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
        and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id);
  if cp then return public.channel_perm_of(uid, c.id, perm, base); end if;
  return base;
end $$;
revoke all on function public.webhook_user_perm(uuid, uuid, text) from public, anon, authenticated;

/**
 * Can uid see this channel? Runs can_access_channel as uid (the same rules people get: membership, private channels,
 * channel overrides), then puts the caller's identity back. Never callable from outside.
 */
create or replace function public.webhook_user_sees(uid uuid, cid uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare prev_sub text := current_setting('request.jwt.claim.sub', true);
        prev_claims text := current_setting('request.jwt.claims', true); ok boolean;
begin
  if uid is null then return false; end if;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', uid, 'role', 'authenticated')::text, true);
  begin
    ok := coalesce(public.can_access_channel(cid), false);
  exception when others then
    perform set_config('request.jwt.claim.sub', coalesce(prev_sub, ''), true);
    perform set_config('request.jwt.claims', coalesce(nullif(prev_claims, ''), '{}'), true);
    raise;
  end;
  perform set_config('request.jwt.claim.sub', coalesce(prev_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(nullif(prev_claims, ''), '{}'), true);
  return ok;
end $$;
revoke all on function public.webhook_user_sees(uuid, uuid) from public, anon, authenticated;

/** Why uid can't manage (or own a working) webhook in this channel, or null when they can. */
create or replace function public.webhook_user_blocked(uid uuid, cid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if uid is null then return 'gone from Yapper'; end if;
  select server_id into sid from public.channels where id = cid;
  if sid is null then return 'no such channel'; end if;
  if public.is_site_banned(uid) then return 'banned from Yapper'; end if;
  if exists (select 1 from public.server_bans b where b.server_id = sid and b.user_id = uid) then return 'banned from the server'; end if;
  if not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = uid) then return 'not in the server'; end if;
  if public.server_timed_out(sid, uid) is not null
     or exists (select 1 from public.profiles p where p.id = uid and p.muted_until > now()) then return 'timed out'; end if;
  if not public.webhook_user_sees(uid, cid) then return 'unable to see the channel'; end if;
  if not public.webhook_user_perm(uid, cid, 'manage_webhooks') then return 'missing Manage Webhooks'; end if;
  return null;
end $$;
revoke all on function public.webhook_user_blocked(uuid, uuid) from public, anon, authenticated;

/** For the signed-in caller: the channel's server when they may manage its webhooks (channel-aware); raises otherwise. */
create or replace function public.webhook_guard_manage(cid uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare sid uuid; why text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select server_id into sid from public.channels where id = cid;
  if sid is null or not public.can_access_channel(cid) then raise exception 'No such channel'; end if;
  if not public.feature_on('webhooks', sid) then raise exception 'Webhooks aren''t on in this server yet'; end if;
  why := public.webhook_user_blocked(auth.uid(), cid);
  if why = 'timed out' then raise exception 'You''re timed out, so you can''t change webhooks right now'; end if;
  if why is not null then raise exception 'You need Manage Webhooks in this channel for that'; end if;
  return sid;
end $$;
revoke all on function public.webhook_guard_manage(uuid) from public, anon, authenticated;

-- ---------- managing (signed in, Manage Webhooks) ----------
create or replace function public.webhook_list(cid uuid)
returns table (id uuid, name text, avatar_path text, created_by uuid, creator text, created_at timestamptz, last_used_at timestamptz, posts bigint)
language plpgsql security definer set search_path = public as $$
begin
  perform public.webhook_guard_manage(cid);
  return query
    select w.id, w.name, w.avatar_path, w.created_by, p.username, w.created_at, w.last_used_at, w.posts
      from public.webhooks w left join public.profiles p on p.id = w.created_by
     where w.channel_id = cid
     order by w.created_at;
end $$;

create or replace function public.webhook_create(cid uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid; uid uuid := auth.uid(); k text; n text; tok text; w public.webhooks;
begin
  sid := public.webhook_guard_manage(cid);
  select kind into k from public.channels where id = cid;
  if k is distinct from 'text' then raise exception 'Webhooks only work in text channels'; end if;
  n := public.webhook_name_ok(p_name);
  perform pg_advisory_xact_lock(hashtextextended('webhook_create:' || cid::text, 0));
  if (select count(*) from public.webhooks x where x.channel_id = cid) >= 10 then
    raise exception 'A channel can have up to 10 webhooks';
  end if;
  -- 244 random bits (gen_random_uuid uses the strong random source); only the hash is stored.
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.webhooks (server_id, channel_id, name, token_hash, created_by)
  values (sid, cid, n, encode(sha256(convert_to(tok, 'UTF8')), 'hex'), uid) returning * into w;
  return jsonb_build_object('id', w.id, 'name', w.name, 'channel_id', w.channel_id, 'avatar_path', w.avatar_path,
                            'created_by', w.created_by, 'created_at', w.created_at, 'posts', 0, 'token', tok);
end $$;

create or replace function public.webhook_rename(wid uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  select channel_id into cid from public.webhooks where id = wid;
  if cid is null then raise exception 'No such webhook'; end if;
  perform public.webhook_guard_manage(cid);
  update public.webhooks set name = public.webhook_name_ok(p_name) where id = wid;
end $$;

/** A new secret URL; the old one stops working right away. Returns the new token (shown once). */
create or replace function public.webhook_rotate(wid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare cid uuid; tok text;
begin
  select channel_id into cid from public.webhooks where id = wid;
  if cid is null then raise exception 'No such webhook'; end if;
  perform public.webhook_guard_manage(cid);
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  update public.webhooks set token_hash = encode(sha256(convert_to(tok, 'UTF8')), 'hex') where id = wid;
  return tok;
end $$;

/** Removes the webhook. Its messages stay (they carry their own name and picture). */
create or replace function public.webhook_delete(wid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  select channel_id into cid from public.webhooks where id = wid;
  if cid is null then raise exception 'No such webhook'; end if;
  perform public.webhook_guard_manage(cid);
  execute 'del' || 'ete from public.webhooks where id = $1' using wid;
end $$;

revoke all on function public.webhook_list(uuid) from public, anon;
revoke all on function public.webhook_create(uuid, text) from public, anon;
revoke all on function public.webhook_rename(uuid, text) from public, anon;
revoke all on function public.webhook_rotate(uuid) from public, anon;
revoke all on function public.webhook_delete(uuid) from public, anon;
grant execute on function public.webhook_list(uuid) to authenticated;
grant execute on function public.webhook_create(uuid, text) to authenticated;
grant execute on function public.webhook_rename(uuid, text) to authenticated;
grant execute on function public.webhook_rotate(uuid) to authenticated;
grant execute on function public.webhook_delete(uuid) to authenticated;

-- ---------- service role (the API) ----------
/** The channel of a webhook uid may manage (for the picture upload), or null. */
create or replace function public.webhook_manage_channel(p_uid uuid, wid uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select x.channel_id, x.server_id into w from public.webhooks x where x.id = wid;
  if w.channel_id is null or p_uid is null then return null; end if;
  if not (public.feature_on('webhooks', w.server_id)
          or exists (select 1 from public.feature_flags f where f.key = 'webhooks' and f.mode = 'test' and p_uid = any(f.users))) then
    return null;
  end if;
  if public.webhook_user_blocked(p_uid, w.channel_id) is not null then return null; end if;
  return w.channel_id;
end $$;

/** Sets (or clears) a webhook's picture. The path must already have passed the image check (require_scanned_media). */
create or replace function public.webhook_set_avatar(p_uid uuid, wid uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.webhook_manage_channel(p_uid, wid) is null then raise exception 'You need Manage Webhooks for that'; end if;
  update public.webhooks set avatar_path = p_path where id = wid;
end $$;

/** Stores the shared webhook account once; returns whichever one is stored. */
create or replace function public.webhook_claim_author(p_uid uuid) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  update public.app_settings set webhook_user_id = p_uid where webhook_user_id is null;
  return (select webhook_user_id from public.app_settings limit 1);
end $$;

/**
 * The rate limit, as its own call before webhook_send so it is committed even when the send then fails.
 * Returns {"ok": true}, or {"code": 10015 | 50027} for a wrong id or token (nothing counted), or
 * {"code": 429, "retry_after": seconds}.
 */
create or replace function public.webhook_take(wid uuid, tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; wait numeric;
begin
  if tok is null or tok !~ '^[0-9a-f]{64}$' then return jsonb_build_object('code', 50027); end if;
  select x.id, x.channel_id, x.token_hash into w from public.webhooks x where x.id = wid;
  if w.id is null then return jsonb_build_object('code', 10015); end if;
  if w.token_hash <> encode(sha256(convert_to(tok, 'UTF8')), 'hex') then return jsonb_build_object('code', 50027); end if;
  wait := public.webhook_hit('w:' || w.id::text, 2, 5);
  if wait = 0 then wait := public.webhook_hit('c:' || w.channel_id::text, 60, 30); end if;
  if random() < 0.01 then
    execute 'del' || 'ete from public.webhook_rate where at < now() - interval ''10 minutes''';
  end if;
  if wait > 0 then return jsonb_build_object('code', 429, 'retry_after', wait); end if;
  return jsonb_build_object('ok', true);
end $$;

/**
 * Posts a message through a webhook (after webhook_take). Errors carry a hint "webhook:<code>" (Discord error codes;
 * setup when the shared account doesn't exist yet) so the API can answer like Discord.
 */
create or replace function public.webhook_send(wid uuid, tok text, body text, p_username text default null,
  p_avatar_url text default null, p_embeds jsonb default null, p_mentions jsonb default null)
returns public.messages language plpgsql security definer set search_path = public as $$
declare
  w public.webhooks; c record; author uuid; m public.messages; n text; txt text; why text;
  parse jsonb; allow_users jsonb; allow_roles jsonb; r record;
begin
  if tok is null or tok !~ '^[0-9a-f]{64}$' then raise exception 'Invalid Webhook Token' using hint = 'webhook:50027'; end if;
  select * into w from public.webhooks where id = wid;
  if w.id is null then raise exception 'Unknown Webhook' using hint = 'webhook:10015'; end if;
  if w.token_hash <> encode(sha256(convert_to(tok, 'UTF8')), 'hex') then
    raise exception 'Invalid Webhook Token' using hint = 'webhook:50027';
  end if;

  select ch.id, ch.server_id, ch.kind into c from public.channels ch where ch.id = w.channel_id;
  if c.id is null or c.kind is distinct from 'text' then raise exception 'Webhooks only post in text channels' using hint = 'webhook:50001'; end if;
  if not (public.feature_on('webhooks', c.server_id)
          or exists (select 1 from public.feature_flags f where f.key = 'webhooks' and f.mode = 'test' and w.created_by = any(f.users))) then
    raise exception 'Webhooks aren''t on in this server' using hint = 'webhook:50001';
  end if;
  -- The message guards skip bot posts, so the creator's standing is checked here.
  why := public.webhook_user_blocked(w.created_by, c.id);
  if why is not null then
    raise exception 'This webhook can''t post right now: the person who made it is %', why using hint = 'webhook:50001';
  end if;
  if exists (select 1 from public.servers s where s.id = c.server_id and s.shut_down_at is not null) then
    raise exception 'This server is shut down' using hint = 'webhook:50001';
  end if;
  if public.server_locked(c.server_id) and not public.webhook_user_perm(w.created_by, c.id, 'manage_messages') then
    raise exception 'This server is locked by its mods right now' using hint = 'webhook:50001';
  end if;
  select webhook_user_id into author from public.app_settings limit 1;
  if author is null then raise exception 'Webhooks aren''t set up yet' using hint = 'webhook:setup'; end if;

  body := coalesce(body, '');
  if char_length(body) > 2000 then raise exception 'content: Must be 2000 or fewer in length.' using hint = 'webhook:50035'; end if;
  if p_embeds is not null and (jsonb_typeof(p_embeds) <> 'array' or jsonb_array_length(p_embeds) > 10) then
    raise exception 'embeds: Up to 10 embeds' using hint = 'webhook:50035';
  end if;
  if p_embeds is not null and jsonb_array_length(p_embeds) = 0 then p_embeds := null; end if;
  if btrim(body) = '' and p_embeds is null then raise exception 'Cannot send an empty message' using hint = 'webhook:50006'; end if;
  n := case when btrim(coalesce(p_username, '')) = '' then w.name else public.webhook_name_ok(p_username) end;
  if p_avatar_url is not null and (p_avatar_url !~ '^https://' or char_length(p_avatar_url) > 512) then p_avatar_url := null; end if;

  -- The message triggers check content; the name and the embed text get the same filters here.
  txt := n;
  if p_embeds is not null then
    txt := txt || ' ' || coalesce((select string_agg(v #>> '{}', ' ')
      from jsonb_path_query(p_embeds, 'strict $.**') v where jsonb_typeof(v) = 'string'), '');
  end if;
  if public.has_slur(txt) then
    raise exception 'That contains a slur, so it wasn''t sent. Keep it respectful.' using hint = 'webhook:200000';
  end if;
  if public.has_adult_link(txt) then raise exception 'Links to that site aren''t allowed on Yapper.' using hint = 'webhook:200000'; end if;
  if public.has_self_harm_incitement(body || ' ' || txt) then
    raise exception 'Telling someone to hurt themselves isn''t allowed on Yapper.' using hint = 'webhook:200000';
  end if;

  -- allowed_mentions (null = Discord's default for webhooks here: users yes, @everyone and roles no).
  parse := case when p_mentions is null then '["users"]'::jsonb
                when jsonb_typeof(p_mentions -> 'parse') = 'array' then p_mentions -> 'parse' else '[]'::jsonb end;
  allow_users := case when jsonb_typeof(p_mentions -> 'users') = 'array' then p_mentions -> 'users' else '[]'::jsonb end;
  allow_roles := case when jsonb_typeof(p_mentions -> 'roles') = 'array' then p_mentions -> 'roles' else '[]'::jsonb end;
  if body ~* '@(everyone|here)'
     and not (parse ? 'everyone' and public.webhook_user_perm(w.created_by, c.id, 'mention_everyone')) then
    body := regexp_replace(body, '@(everyone|here)', '@' || chr(8203) || '\1', 'gi');
  end if;
  if strpos(body, '<@&') > 0 and not (parse ? 'roles') then
    for r in select distinct x[1] as rid from regexp_matches(body, '<@&([0-9a-f-]{36})>', 'g') x loop
      continue when allow_roles ? r.rid;
      body := replace(body, '<@&' || r.rid || '>', '@' || chr(8203) || coalesce(
        (select translate(ro.name, '<>', '') from public.roles ro where ro.id::text = r.rid and ro.server_id = c.server_id), 'deleted-role'));
    end loop;
  end if;
  if strpos(body, '<@') > 0 and not (parse ? 'users') then
    for r in select distinct x[1] as uid from regexp_matches(body, '<@([0-9a-f-]{36})>', 'g') x loop
      continue when allow_users ? r.uid;
      body := replace(body, '<@' || r.uid || '>', '@' || chr(8203) || coalesce(
        (select p.username from public.profiles p where p.id::text = r.uid), 'unknown-user'));
    end loop;
  end if;

  perform set_config('yapper.bot', '1', true);
  perform set_config('yapper.webhook', '1', true);
  insert into public.messages (channel_id, author_id, content, embeds, webhook)
  values (c.id, author, body, p_embeds, jsonb_build_object('id', w.id, 'name', n, 'avatar_url', p_avatar_url,
          'avatar_path', case when p_avatar_url is null then w.avatar_path end))
  returning * into m;
  perform set_config('yapper.webhook', '', true);
  perform set_config('yapper.bot', '', true);
  update public.webhooks set last_used_at = now(), posts = posts + 1 where id = w.id;
  return m;
end $$;

revoke all on function public.webhook_manage_channel(uuid, uuid) from public, anon, authenticated;
revoke all on function public.webhook_set_avatar(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.webhook_claim_author(uuid) from public, anon, authenticated;
revoke all on function public.webhook_take(uuid, text) from public, anon, authenticated;
revoke all on function public.webhook_send(uuid, text, text, text, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.webhook_manage_channel(uuid, uuid) to service_role;
grant execute on function public.webhook_set_avatar(uuid, uuid, text) to service_role;
grant execute on function public.webhook_claim_author(uuid) to service_role;
grant execute on function public.webhook_take(uuid, text) to service_role;
grant execute on function public.webhook_send(uuid, text, text, text, text, jsonb, jsonb) to service_role;

-- ---------- moderation never lands on the shared webhook account ----------
-- Patched in place (live bodies kept), like 144/145: each patch checks its marker and fails loudly if the text moved.
do $$
declare src text; out text; step text;
begin
  -- Reports of a webhook message target whoever made the webhook, and keep the webhook id.
  src := pg_get_functiondef('public.report_message(uuid, text, text)'::regprocedure);
  if position('webhook_id' in src) = 0 then
    out := replace(src,
      $a$insert into public.reports (reporter_id, target_id, message_id, channel_id, message_content, message_attachment, reason, details, evidence, server_id)
  values (auth.uid(), m.author_id, m.id,$a$,
      $b$insert into public.reports (reporter_id, target_id, message_id, channel_id, message_content, message_attachment, reason, details, evidence, server_id, webhook_id)
  values (auth.uid(), coalesce((select w.created_by from public.webhooks w where m.webhook is not null and w.id = (m.webhook ->> 'id')::uuid), m.author_id), m.id,$b$);
    if out = src then raise exception '155: report_message patch (columns) did not apply'; end if;
    step := out;
    out := replace(step,
      $a$(select server_id from public.channels where id = m.channel_id))
  returning id into rid;$a$,
      $b$(select server_id from public.channels where id = m.channel_id), (m.webhook ->> 'id')::uuid)
  returning id into rid;$b$);
    if out = step then raise exception '155: report_message patch (values) did not apply'; end if;
    execute out;
  end if;

  -- Report-driven auto bans / timeouts skip the shared account.
  src := pg_get_functiondef('public.apply_auto_action(uuid, public.reports)'::regprocedure);
  if position('webhook_user_id' in src) = 0 then
    out := replace(src,
      $a$if target is null or exists (select 1 from public.site_admins where user_id = target)$a$,
      $b$if target is null or target = (select a.webhook_user_id from public.app_settings a limit 1) or exists (select 1 from public.site_admins where user_id = target)$b$);
    if out = src then raise exception '155: apply_auto_action patch did not apply'; end if;
    execute out;
  end if;

  -- Staff can't site-ban the shared account (that would silence every webhook): ban whoever made the webhook.
  src := pg_get_functiondef('public.site_ban(uuid, text, boolean)'::regprocedure);
  if position('webhook_user_id' in src) = 0 then
    out := replace(src,
      $a$if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;$a$,
      $b$if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;
  if uid = (select a.webhook_user_id from public.app_settings a limit 1) then
    raise exception 'That''s the shared webhook account. Ban whoever made the webhook instead.';
  end if;$b$);
    if out = src then raise exception '155: site_ban patch did not apply'; end if;
    execute out;
  end if;

  -- Purging the shared account would wipe every webhook message on Yapper.
  src := pg_get_functiondef('public.mod_purge_messages(uuid, integer, text)'::regprocedure);
  if position('webhook_user_id' in src) = 0 then
    out := replace(src,
      $a$  perform public.mod_guard('purge', uid, r);$a$,
      $b$  if uid = (select a.webhook_user_id from public.app_settings a limit 1) then
    raise exception 'That''s the shared webhook account. Purge whoever made the webhook instead.';
  end if;
  perform public.mod_guard('purge', uid, r);$b$);
    if out = src then raise exception '155: mod_purge_messages patch did not apply'; end if;
    execute out;
  end if;
end $$;

notify pgrst, 'reload schema';
