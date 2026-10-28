-- 355: bot gateway (flag bot_gateway). Applied live Oct 21 11:47 UTC as "339_bot_gateway" (339 and 351 were taken by
-- other chats, so the file moved to 355). Bots hold a WebSocket to the realtime server (ops/realtime/botGateway.mjs)
-- instead of long-polling GET /api/bot/v1/events. The realtime server reads bot_events for every connected bot in one
-- call a second, so ~110 polls a second on Supabase's gateway become one request on our own PostgREST.
--
-- The realtime VPS has no service key. These three functions are callable with the anon key but only do anything
-- when given the gateway secret (vault gw_secret = GATEWAY_SECRET in the VPS .env). It is its own secret, not
-- rt_secret: these read every bot's events, so a leaked publish secret shouldn't also open that. No gw_secret in the
-- vault: every call is refused and bots stay on the long poll. Everything a bot may see is still decided when
-- bot_events rows are written (bot_push). The functions are volatile so PostgREST only takes them as POST (the
-- secret never lands in a URL or a log line).
-- Only new functions and a flag row: no table changes. Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bot_gateway', 'Bot gateway', 'Bots get their events over a WebSocket on our realtime server instead of long polling', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- The caller is our realtime server. Not callable on its own.
create or replace function public.gateway_secret_ok(p_secret text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(length(p_secret), 0) >= 16
     and exists (select 1 from vault.decrypted_secrets where name = 'gw_secret' and decrypted_secret = p_secret);
$$;
revoke all on function public.gateway_secret_ok(text) from public, anon, authenticated;

-- The bot behind a token hash (sha256 hex, like the bot API): a normal bot token or a hosting token. Same rules as
-- botFromRequest (lib/server/bots.ts); the hosting free-slot rule needs an env var, so `until` and `free_slot` come
-- back for the realtime server to decide. `gateway` is the flag for the bot's owner, like serverFlagOn. `newest` is
-- the bot's latest event id, for "start from now" connects. Null when nothing matches.
create or replace function public.gateway_bot_auth(p_secret text, p_hash text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b record; f record; on_ boolean := false; h_bot uuid; h_until timestamptz; h_free boolean;
begin
  if not public.gateway_secret_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then return null; end if;
  select id, owner_id, name into b from public.bots where token_hash = p_hash;
  if b.id is null then
    select bot_id, until, free_slot into h_bot, h_until, h_free from public.bot_hosting
     where host_token_hash = p_hash and blocked = false and want_running = true;
    if h_bot is null then return null; end if;
    select id, owner_id, name into b from public.bots where id = h_bot;
    if b.id is null then return null; end if;
  end if;
  select mode, servers, users into f from public.feature_flags where key = 'bot_gateway';
  if f.mode = 'everyone' then on_ := true;
  elsif f.mode = 'test' then
    on_ := b.owner_id = any(coalesce(f.users, '{}'))
        or exists (select 1 from public.server_members m where m.user_id = b.owner_id and m.server_id = any(coalesce(f.servers, '{}')));
  end if;
  return jsonb_build_object(
    'id', b.id, 'owner_id', b.owner_id, 'name', b.name, 'gateway', on_,
    'hosted', h_bot is not null, 'until', h_until, 'free_slot', coalesce(h_free, false),
    'newest', coalesce((select e.id from public.bot_events e where e.bot_id = b.id order by e.id desc limit 1), 0));
end $$;
revoke all on function public.gateway_bot_auth(text, text) from public, anon, authenticated;
grant execute on function public.gateway_bot_auth(text, text) to anon;

-- New events for many bots at once: up to p_limit (max 100) per bot after each bot's cursor, in id order, and at most
-- 5000 rows a call (the caller looks again soon when it gets that many). Uses bot_events_bot_idx (bot_id, id) once per bot.
create or replace function public.gateway_bot_events(p_secret text, p_bots uuid[], p_after bigint[], p_limit int default 100)
returns table (bot_id uuid, id bigint, type text, data jsonb, created_at timestamptz)
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.gateway_secret_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(cardinality(p_bots), 0) = 0 then return; end if;
  if cardinality(p_bots) > 1000 or cardinality(p_bots) <> coalesce(cardinality(p_after), 0) then
    raise exception 'bad request' using errcode = '22023';
  end if;
  return query
    select c.bid, e.id, e.type, e.data, e.created_at
      from unnest(p_bots, p_after) as c(bid, aft)
      cross join lateral (
        select x.id, x.type, x.data, x.created_at from public.bot_events x
         where x.bot_id = c.bid and x.id > coalesce(c.aft, 0)
         order by x.id limit least(greatest(coalesce(p_limit, 100), 1), 100)) e
     order by c.bid, e.id
     limit 5000;
end $$;
revoke all on function public.gateway_bot_events(text, uuid[], bigint[], int) from public, anon, authenticated;
grant execute on function public.gateway_bot_events(text, uuid[], bigint[], int) to anon;

-- Connected bots show as online, like each long poll does (last_poll_at + bot_presence). Called about once a minute.
create or replace function public.gateway_bot_presence(p_secret text, p_bots uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare bid uuid; n int := 0;
begin
  if not public.gateway_secret_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(cardinality(p_bots), 0) = 0 then return 0; end if;
  if cardinality(p_bots) > 1000 then raise exception 'bad request' using errcode = '22023'; end if;
  -- One statement, then presence in id order: no lock-order deadlocks with other writers of these rows.
  update public.bots set last_poll_at = now() where id = any(p_bots);
  for bid in select b.id from public.bots b where b.id = any(p_bots) order by b.id loop
    perform public.bot_presence(bid);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.gateway_bot_presence(text, uuid[]) from public, anon, authenticated;
grant execute on function public.gateway_bot_presence(text, uuid[]) to anon;
