// 212: bot message limits: 30 a minute per server, 30 (unverified) / 300 (verified) a minute overall, and replies to a
// slash command or a button press don't count overall. bot_api_send, bot_api_post and bot_interaction_respond are
// copied verbatim from the live database (read-only, Oct 18) so the in-place patches are checked against the real
// text; their other dependencies are small stand-ins.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
-- The stage-24 message triggers (new-account pacing etc.) are not what this tests.
alter table public.messages disable trigger user;
alter table public.messages add column if not exists reply_to_id uuid;
alter table public.messages add column if not exists embeds jsonb;
alter table public.messages add column if not exists components jsonb;
alter table public.messages add column if not exists webhook uuid;
create table if not exists public.bots (id uuid primary key, owner_id uuid, name text, verified_at timestamptz,
  last_used_at timestamptz, posts bigint not null default 0);
create table if not exists public.bot_commands (bot_id uuid, name text, description text);
create table if not exists public.bot_interactions (id uuid primary key default gen_random_uuid(), bot_id uuid, user_id uuid,
  server_id uuid, channel_id uuid, message_id uuid, token text, replies int not null default 0, answered_at timestamptz,
  created_at timestamptz not null default now());
create table if not exists public.bot_interaction_replies (id uuid primary key default gen_random_uuid(), interaction_id uuid,
  bot_id uuid, user_id uuid, channel_id uuid, message_id uuid, kind text, content text, embeds jsonb);
create schema if not exists extensions;
create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.bots where id = uid) $$;
create or replace function extensions.digest(t text, alg text) returns bytea language sql immutable as $$ select convert_to(t, 'UTF8') $$;
create or replace function public.bot_channel_visible(bid uuid, cid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.bc(topic text, kind text, op text, tbl text, sch text, n record, o record) returns void language plpgsql as $$ begin end $$;
create or replace function public.bot_api_edit(bid uuid, mid uuid, body text, e jsonb, se boolean, c jsonb, sc boolean)
  returns public.messages language sql as $$ select * from public.messages where id = mid $$;
`;

const LIVE = String.raw`
CREATE OR REPLACE FUNCTION public.bot_api_send(bid uuid, cid uuid, body text, reply uuid DEFAULT NULL::uuid, p_embeds jsonb DEFAULT NULL::jsonb, p_components jsonb DEFAULT NULL::jsonb)
 RETURNS messages
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m public.messages; recent int; sid uuid;
begin
  if not public.bot_channel_visible(bid, cid) then raise exception 'No such channel, or the bot cannot see it'; end if;
  if exists (select 1 from public.channels c where c.id = cid and c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id)) then
    raise exception 'Chat in voice channels isn''t on in this server';
  end if;
  -- Lock the bot's own row first: one send per bot at a time (parallel calls can't all slip under the limit),
  -- and taken before the insert so it never waits while holding locks the message triggers took.
  -- A failed send below rolls this back too.
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  select count(*) into recent from public.messages where author_id = bid and created_at > now() - interval '1 minute';
  if recent >= 30 then raise exception 'Slow down: 30 messages a minute per bot' using errcode = 'P0001'; end if;
  select server_id into sid from public.channels where id = cid;
  if p_embeds is not null and not public.feature_on('bot_embeds', sid) then raise exception 'Embeds aren''t available in this server yet'; end if;
  if p_components is not null and not public.feature_on('bot_buttons', sid) then raise exception 'Buttons aren''t available in this server yet'; end if;
  if (body is null or btrim(body) = '') and p_embeds is null then raise exception 'Empty message: send content or embeds'; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id, embeds, components)
  values (cid, bid, left(coalesce(body, ''), 2000), reply, p_embeds, p_components) returning * into m;
  perform set_config('yapper.bot', '', true);
  return m;
end $function$;

CREATE OR REPLACE FUNCTION public.bot_api_post(bid uuid, cid uuid, body text, reply uuid DEFAULT NULL::uuid)
 RETURNS messages
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m public.messages; recent int;
begin
  if not public.bot_channel_visible(bid, cid) then raise exception 'No such channel, or the bot cannot see it'; end if;
  if exists (select 1 from public.channels c where c.id = cid and c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id)) then
    raise exception 'Chat in voice channels isn''t on in this server';
  end if;
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  select count(*) into recent from public.messages where author_id = bid and created_at > now() - interval '1 minute';
  if recent >= 30 then raise exception 'Slow down: 30 messages a minute per bot' using errcode = 'P0001'; end if;
  if body is null or btrim(body) = '' then raise exception 'Empty message'; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id) values (cid, bid, left(body, 2000), reply) returning * into m;
  perform set_config('yapper.bot', '', true);
  return m;
end $function$;

CREATE OR REPLACE FUNCTION public.bot_interaction_respond(bid uuid, iid uuid, tok text, kind text, body text DEFAULT NULL::text, p_embeds jsonb DEFAULT NULL::jsonb, p_components jsonb DEFAULT NULL::jsonb, set_embeds boolean DEFAULT false, set_components boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare i public.bot_interactions; r public.bot_interaction_replies; msg public.messages; h text; prev public.bot_interactions;
begin
  if tok is null or tok !~ '^[0-9a-f]{48}$' then raise exception 'No such interaction'; end if;
  h := encode(extensions.digest(tok, 'sha256'), 'hex');
  -- One atomic claim: right bot, right token, not expired, under 10 answers. (Raising later undoes it.)
  update public.bot_interactions set replies = replies + 1, answered_at = coalesce(answered_at, now())
   where id = iid and bot_id = bid and token = h and created_at > now() - interval '15 minutes' and replies < 10
  returning * into i;
  if i.id is null then
    select * into prev from public.bot_interactions where id = iid and bot_id = bid and token = h;
    if prev.id is null then raise exception 'No such interaction'; end if;
    if prev.created_at <= now() - interval '15 minutes' then raise exception 'That interaction expired: answer within 15 minutes'; end if;
    raise exception 'Slow down: up to 10 answers per interaction';
  end if;
  if not public.bot_channel_visible(bid, i.channel_id) then raise exception 'That bot can''t see this channel anymore'; end if;
  if kind = 'reply' then
    msg := public.bot_api_send(bid, i.channel_id, body, null, p_embeds, p_components);
  elsif kind = 'update' then
    msg := public.bot_api_edit(bid, i.message_id, body, p_embeds, set_embeds, p_components, set_components);
  elsif kind = 'ephemeral' then
    if btrim(coalesce(body, '')) = '' and p_embeds is null then raise exception 'An ephemeral reply needs content or embeds'; end if;
    if p_embeds is not null and not public.feature_on('bot_embeds', i.server_id) then raise exception 'Embeds aren''t available in this server yet'; end if;
  elsif kind is distinct from 'ack' then
    raise exception 'type must be reply, ephemeral, update or ack';
  end if;
  insert into public.bot_interaction_replies (interaction_id, bot_id, user_id, channel_id, message_id, kind, content, embeds)
  values (i.id, bid, i.user_id, i.channel_id, i.message_id, kind,
          case when kind = 'ephemeral' then left(coalesce(body, ''), 2000) end, case when kind = 'ephemeral' then p_embeds end)
  returning * into r;
  perform public.bc('user:' || i.user_id, 'interaction', 'INSERT', 'bot_interaction_replies', 'public', r, null);
  return jsonb_build_object('ok', true, 'type', kind, 'message', case when msg.id is null then null else to_jsonb(msg) end);
end $function$;
`;

export default async function (h) {
  const owner = await h.signup('owner@test.dev', 'owner');
  const human = await h.signup('human@test.dev', 'human');
  const bot = await h.signup('bot@bots.test', 'bigbot');
  const vbot = await h.signup('vbot@bots.test', 'verifiedbot');
  await h.as(owner);
  const S1 = (await h.one(`select create_server('One', null) id`)).id;
  const S2 = (await h.one(`select create_server('Two', null) id`)).id;
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  const chan = async (s, name) => (await h.one(`insert into channels (server_id, kind, name) values ($1, 'text', $2) returning id`, [s, name])).id;
  const C1 = await chan(S1, 'one');
  const C2 = await chan(S2, 'two');
  const C3 = await chan(S1, 'three');
  for (const s of [S1, S2]) for (const u of [human, bot, vbot]) {
    await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [s, u]);
  }
  await h.q(`insert into bots (id, owner_id, name) values ($1, $2, 'big'), ($3, $2, 'verified')`, [bot, owner, vbot]);
  await h.q(`update bots set verified_at = now() where id = $1`, [vbot]);
  await h.q(`insert into bot_commands (bot_id, name) values ($1, 'ping'), ($2, 'ping')`, [bot, vbot]);

  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '212_bot_rate_limits.sql'), 'utf8');
  await h.db.exec(sql);
  await h.db.exec(sql); // re-runnable
  for (const f of ['bot_api_send(uuid,uuid,text,uuid,jsonb,jsonb)', 'bot_api_post(uuid,uuid,text,uuid)', 'bot_interaction_respond(uuid,uuid,text,text,text,jsonb,jsonb,boolean,boolean)']) {
    const src = (await h.one(`select pg_get_functiondef('public.${f}'::regprocedure) d`)).d;
    h.eq(`${f.split('(')[0]} patched once`, (src.match(/212:/g) ?? []).length, 1);
  }

  const send = (b, c, body = 'hi', reply = null) => h.q(`select (bot_api_send($1, $2, $3, $4)).id`, [b, c, body, reply]);
  const errOf = async (p) => { try { await p; return null; } catch (e) { return e.message; } };
  const reset = async () => {
    await h.q(`update messages set created_at = created_at - interval '5 minutes' where author_id in ($1, $2)`, [bot, vbot]);
    await h.q(`update bots set rate_min = null, rate_cur = 0, rate_prev = 0`);
  };

  // Per server: 30 a minute, in one server, even for a verified bot. Another server is unaffected.
  for (let i = 0; i < 30; i++) await send(vbot, i % 2 ? C1 : C3);
  const perServer = await errOf(send(vbot, C1));
  h.eq('31st message in one server is refused', /^Slow down: 30 messages a minute in this server \(try again in \d+ s\)$/.test(perServer ?? ''), true);
  h.eq('the bot can still post in another server', (await send(vbot, C2)).length, 1);
  h.eq('bot_api_post has the same per-server limit', /in this server/.test(await errOf(h.q(`select bot_api_post($1, $2, 'x')`, [vbot, C1])) ?? ''), true);

  // Overall: 30 a minute for an unverified bot across servers.
  await reset();
  for (let i = 0; i < 30; i++) {
    const s = await h.one(`insert into servers (name, owner_id) values ('S' || $1, $2) returning id`, [i, owner]);
    await h.q(`insert into channels (server_id, kind, name) values ($1, 'text', 'c')`, [s.id]);
  }
  const many = (await h.q(`select c.id from channels c join servers s on s.id = c.server_id where s.name like 'S%' order by s.name`)).map((r) => r.id);
  for (let i = 0; i < 30; i++) await send(bot, many[i]);
  const overall = await errOf(send(bot, C2));
  h.eq('unverified bot: 31st message overall is refused', /^Slow down: 30 messages a minute overall \(try again in \d+ s\)$/.test(overall ?? ''), true);

  // ...but a reply to someone's slash command for this bot still goes through (up to 5 per command message).
  const cmd = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, '/ping now') returning id`, [C2, human])).id;
  for (let i = 0; i < 5; i++) await send(bot, C2, 'pong', cmd);
  h.eq('5 command replies are free', (await h.one(`select count(*)::int n from messages where reply_to_id = $1`, [cmd])).n, 5);
  h.eq('the 6th reply to the same command counts again', /overall/.test(await errOf(send(bot, C2, 'pong', cmd)) ?? ''), true);
  const notCmd = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, '/unknown') returning id`, [C2, human])).id;
  h.eq('a reply to a command the bot did not register counts', /overall/.test(await errOf(send(bot, C2, 'x', notCmd)) ?? ''), true);
  const otherChan = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, '/ping') returning id`, [C3, human])).id;
  h.eq('a "reply" to a command in another channel counts', /overall/.test(await errOf(send(bot, C2, 'x', otherChan)) ?? ''), true);
  const old = (await h.one(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, '/ping', now() - interval '20 minutes') returning id`, [C2, human])).id;
  h.eq('a reply to a 20 minute old command counts', /overall/.test(await errOf(send(bot, C2, 'x', old)) ?? ''), true);

  // Another bot's or a webhook's "/ping" isn't a command from a person, so replying to it counts.
  const fromBot = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, '/ping') returning id`, [C2, vbot])).id;
  h.eq('a reply to another bot\'s "/command" counts', /overall/.test(await errOf(send(bot, C2, 'x', fromBot)) ?? ''), true);
  const fromHook = (await h.one(`insert into messages (channel_id, author_id, content, webhook) values ($1, $2, '/ping', gen_random_uuid()) returning id`, [C2, human])).id;
  h.eq('a reply to a webhook\'s "/command" counts', /overall/.test(await errOf(send(bot, C2, 'x', fromHook)) ?? ''), true);

  // A button press answer is free overall too (it goes through bot_interaction_respond).
  const tok = 'ab'.repeat(24);
  const iid = (await h.one(`insert into bot_interactions (bot_id, user_id, server_id, channel_id, token) values ($1, $2, $3, $4, encode(convert_to($5, 'UTF8'), 'hex')) returning id`, [bot, human, S2, C2, tok])).id;
  const ans = await h.one(`select bot_interaction_respond($1, $2, $3, 'reply', 'clicked') r`, [bot, iid, tok]);
  h.eq('button answer goes through while the overall cap is full', ans.r.ok, true);
  h.eq('the reply flag is cleared afterwards', (await h.one(`select coalesce(current_setting('yapper.bot_reply', true), '') v`)).v, '');

  // Verified bots get 300 overall.
  await reset();
  for (let i = 0; i < 30; i++) await send(vbot, many[i]);
  h.eq('verified bot: 31st message overall is fine', (await send(vbot, C2)).length, 1);
  await h.q(`update bots set rate_min = date_trunc('minute', now()), rate_cur = 300, rate_prev = 0 where id = $1`, [vbot]);
  h.eq('verified bot: over 300 overall is refused', /^Slow down: 300 messages a minute overall/.test(await errOf(send(vbot, C1)) ?? ''), true);

  // The previous minute fades out: 60 last minute still blocks for the first half of this one (60 x (1 - t/60) >= 30).
  await h.q(`update bots set rate_min = date_trunc('minute', now()) - interval '1 minute', rate_cur = 60, rate_prev = 0 where id = $1`, [bot]);
  const est = await errOf(send(bot, many[0]));
  const sec = Number((await h.one(`select extract(second from now())::int s`)).s);
  h.eq('the minute before still counts (sliding window)', sec < 28 ? /overall/.test(est ?? '') : sec > 32 ? est === null : true, true);

  // A refused send changes nothing.
  await h.q(`update bots set rate_min = date_trunc('minute', now()), rate_cur = 30, rate_prev = 0 where id = $1`, [bot]);
  const posts = (await h.one(`select posts from bots where id = $1`, [bot])).posts;
  h.eq('full counter refuses', /overall/.test(await errOf(send(bot, many[0])) ?? ''), true);
  h.eq('a refused send does not count as a post', (await h.one(`select posts, rate_cur from bots where id = $1`, [bot])), { posts, rate_cur: 30 });

  // Nobody else can call the gate.
  await h.as(owner);
  await h.fails('users cannot call bot_send_gate', `select bot_send_gate($1, $2)`, [bot, C1]);
}
