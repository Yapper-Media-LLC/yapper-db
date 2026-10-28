// 184: bot voice (flag bot_voice). bot_voice_gate (in server, flag on for that server, 30 actions a minute) and
// bot_voice_event (the LiveKit webhook's one call: voice_join / voice_leave to the bots that can see the channel).
// Like stage157 this starts from stage 24, adds small stand-ins for the live pieces 184 leans on, then the live
// definitions of bot_push, bot_channel_visible and feature_on, copied verbatim from the live database
// (read-only, Oct 17), so the events go through the real bot_push and the real flag rules.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

export const STANDINS = `
alter table public.channels add column if not exists category_id uuid;
create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.bots (id uuid primary key references public.profiles (id) on delete cascade, owner_id uuid,
  webhook_url text, webhook_secret text, last_event_at timestamptz);
create table if not exists public.bot_servers (bot_id uuid references public.bots (id) on delete cascade,
  server_id uuid references public.servers (id) on delete cascade, primary key (bot_id, server_id));
create table if not exists public.bot_events (id bigserial primary key, bot_id uuid, type text, data jsonb, created_at timestamptz not null default now());
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql stable as $$ select base $$;
create schema if not exists extensions;
create or replace function extensions.hmac(data text, key text, typ text) returns bytea language sql immutable as $$ select convert_to(key || ':' || data, 'utf8') $$;
create schema if not exists net;
create table if not exists net.posts (url text, headers jsonb, body jsonb);
create or replace function net.http_post(url text, headers jsonb, body jsonb, timeout_milliseconds int) returns bigint language plpgsql as $$
begin insert into net.posts values (url, headers, body); return 1; end $$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
export const LIVE = String.raw`
CREATE OR REPLACE FUNCTION public.bot_channel_visible(bid uuid, cid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.channels c
    where c.id = cid
      and (
        (c.server_id is not null and exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = c.server_id)
          and case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
            then public.channel_perm_of(bid, c.id, 'view_channel',
                   exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid)
                   or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = bid where cr.channel_id = c.id))
            else (not c.private
               or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid)
               or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = bid where cr.channel_id = c.id))
          end)
        or (c.server_id is null and exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid))
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.bot_push(bid uuid, hook_url text, hook_secret text, ev text, payload jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare body text; sig text; cid uuid; sid uuid; eid bigint;
begin
  -- Every event carries channel_id and server_id (null when the event isn't in a channel / is in a DM).
  payload := coalesce(payload, '{}'::jsonb);
  cid := nullif(payload ->> 'channel_id', '')::uuid;
  if cid is null and nullif(payload ->> 'message_id', '') is not null then
    select channel_id into cid from public.messages where id = (payload ->> 'message_id')::uuid;
  end if;
  sid := nullif(payload ->> 'server_id', '')::uuid;
  if sid is null and cid is not null then select server_id into sid from public.channels where id = cid; end if;
  payload := payload || jsonb_build_object('channel_id', cid, 'server_id', sid);
  insert into public.bot_events (bot_id, type, data) values (bid, ev, payload) returning id into eid;
  -- Never wait for the bots row here (that is what deadlocked parallel sends); a minute-old stamp is fine.
  update public.bots set last_event_at = now()
   where id in (select b.id from public.bots b
                 where b.id = bid and (b.last_event_at is null or b.last_event_at < now() - interval '1 minute')
                 for no key update skip locked);
  if hook_url is not null then
    body := jsonb_build_object('id', eid, 'event', ev, 'data', payload)::text;
    sig := encode(extensions.hmac(body, coalesce(hook_secret, ''), 'sha256'), 'hex');
    perform net.http_post(
      url := hook_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Yapper-Signature', 'sha256=' || sig, 'X-Yapper-Bot', bid::text),
      body := body::jsonb,
      timeout_milliseconds := 3000);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.feature_on(k text, sid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false);
$function$;
`;

const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '184_bot_voice.sql'), 'utf8');

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(MIGRATION);
  await h.ok('184 re-runs cleanly', () => h.db.exec(MIGRATION));
  h.eq('no plain drop / delete-from in the file (Supabase MCP hangs on them)', /\bdrop\s|\bdelete\s+from\b/i.test(MIGRATION), false);
  h.eq('no em dashes in user-facing text', MIGRATION.includes('—'), false);
  h.eq('flag added in test mode with no servers', await h.one(`select mode, servers from feature_flags where key = 'bot_voice'`), { mode: 'test', servers: [] });

  const err = async (sql, params = []) => { try { await h.db.query(sql, params); return null; } catch (e) { return e; } };

  const owner = await h.signup('owner@test.dev', 'owner');
  const alice = await h.signup('alice@test.dev', 'alice');
  const botA = await h.signup('bota@test.dev', 'bot_a');
  const botB = await h.signup('botb@test.dev', 'bot_b');
  const botC = await h.signup('botc@test.dev', 'bot_c');
  await h.as(owner);
  const sid = (await h.one(`select create_server('Voice', null) id`)).id;
  const other = (await h.one(`select create_server('Other', null) id`)).id;
  await h.admin();
  const vc = (await h.one(`select id from channels where server_id = $1 and kind = 'voice' limit 1`, [sid])).id;
  const text = (await h.one(`select id from channels where server_id = $1 and kind = 'text' limit 1`, [sid])).id;
  const secret = (await h.one(`insert into channels (kind, name, server_id, created_by, private) values ('voice', 'Staff VC', $1, $2, true) returning id`, [sid, owner])).id;
  const otherVc = (await h.one(`select id from channels where server_id = $1 and kind = 'voice' limit 1`, [other])).id;
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', 'k1', $1) returning id`, [owner])).id;
  await h.q(`insert into bots (id, owner_id, webhook_url, webhook_secret) values ($1, $4, 'https://bot.example/hook', 's3cret'), ($2, $4, null, null), ($3, $4, null, null)`, [botA, botB, botC, owner]);
  // A and B are in the server, C only in the other one. B is let into the private channel through channel_members.
  await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $3), ($2, $3), ($4, $5)`, [botA, botB, sid, botC, other]);
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2)`, [secret, botB]);

  const gate = async (bid, s, act = false) => { await h.admin(); return (await h.one(`select bot_voice_gate($1, $2, $3) r`, [bid, s, act])).r; };
  const event = async (cid, uid, ev) => { await h.admin(); return (await h.one(`select bot_voice_event($1, $2, $3) n`, [cid, uid, ev])).n; };
  const events = async () => { await h.admin(); return h.q(`select bot_id, type, data from bot_events order by id`); };
  const clear = async () => { await h.admin(); await h.q(`delete from bot_events`); await h.q(`delete from net.posts`); };

  // ---- gate ----
  h.eq('gate: bot not in that server', await gate(botC, sid), 'The bot is not in that server');
  h.eq('gate: flag off for the server (test mode, not listed)', await gate(botA, sid), 'Bot voice isn\'t on in this server yet');
  await h.q(`update feature_flags set users = array[$1::uuid, $2::uuid] where key = 'bot_voice'`, [owner, botA]);
  h.eq('gate: listing users does not turn it on for a server (no auth.uid as service role)', await gate(botA, sid), 'Bot voice isn\'t on in this server yet');
  h.eq('event: flag off sends nothing', await event(vc, alice, 'voice_join'), 0);
  h.eq('event: nothing queued while off', (await events()).length, 0);
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'bot_voice'`, [sid]);
  h.eq('gate: on for a listed server', await gate(botA, sid), null);
  h.eq('gate: still off for another server', await gate(botC, other), 'Bot voice isn\'t on in this server yet');

  // ---- rate limit: 30 actions a minute per bot ----
  let last = null;
  for (let i = 0; i < 30; i++) last = await gate(botA, sid, true);
  h.eq('30 moves a minute are fine', last, null);
  h.eq('the 31st is refused', await gate(botA, sid, true), 'Slow down: 30 voice moves a minute per bot');
  h.eq('lookups (act = false) have their own bucket', await gate(botA, sid, false), null);
  for (let i = 0; i < 58; i++) last = await gate(botA, sid, false);
  h.eq('60 lookups a minute are fine', last, null);
  h.eq('the 61st lookup is refused', await gate(botA, sid, false), 'Slow down: 60 voice lookups a minute per bot');
  h.eq('lookups did not touch the move count', (await h.one(`select n from bot_voice_rate where bot_id = $1`, [botA])).n, 31);
  await h.q(`update bot_voice_rate set read_window_start = now() - interval '61 seconds' where bot_id = $1`, [botA]);
  h.eq('a minute later lookups start over', await gate(botA, sid, false), null);
  h.eq('a refused gate (flag off) counts nothing', [await gate(botC, other, false), (await h.one(`select read_n, n from bot_voice_rate where bot_id = $1`, [botC])) ?? null], ['Bot voice isn\'t on in this server yet', null]);
  h.eq('another bot has its own count', await gate(botB, sid, true), null);
  await h.q(`update bot_voice_rate set window_start = now() - interval '61 seconds' where bot_id = $1`, [botA]);
  h.eq('a minute later it starts over', await gate(botA, sid, true), null);
  h.eq('counter restarted at 1', (await h.one(`select n from bot_voice_rate where bot_id = $1`, [botA])).n, 1);
  h.eq('one rate row per bot', (await h.one(`select count(*)::int n from bot_voice_rate`)).n, 2);

  // ---- events ----
  await clear();
  h.eq('join in a public voice channel reaches both bots', await event(vc, alice, 'voice_join'), 2);
  const ev1 = await events();
  const flat = (e) => [e.bot_id, e.type, e.data.user_id, e.data.channel_id, e.data.server_id, Object.keys(e.data).length];
  h.eq('payload: user, channel, server', ev1.map(flat).sort((a, b) => a[0].localeCompare(b[0])),
    [[botA, 'voice_join', alice, vc, sid, 3], [botB, 'voice_join', alice, vc, sid, 3]].sort((a, b) => a[0].localeCompare(b[0])));
  const posts = await h.q(`select url, body from net.posts`);
  h.eq('the bot with a webhook gets it posted too', posts.map((p) => [p.url, p.body.event, p.body.data.user_id]), [['https://bot.example/hook', 'voice_join', alice]]);

  await clear();
  h.eq('private channel: only the bot let in', await event(secret, alice, 'voice_leave'), 1);
  h.eq('private channel: that bot, voice_leave', (await events()).map((e) => [e.bot_id, e.type]), [[botB, 'voice_leave']]);

  await clear();
  h.eq('the participant itself gets no event about itself', await event(vc, botA, 'voice_join'), 1);
  h.eq('only the other bot hears it', (await events()).map((e) => e.bot_id), [botB]);

  await clear();
  h.eq('text channel: nothing', await event(text, alice, 'voice_join'), 0);
  h.eq('DM call: nothing', await event(dm, alice, 'voice_join'), 0);
  h.eq('unknown room: nothing', await event('00000000-0000-0000-0000-000000000000', alice, 'voice_join'), 0);
  h.eq('server where the flag is off: nothing', await event(otherVc, alice, 'voice_join'), 0);
  h.eq('nothing queued for those', (await events()).length, 0);
  h.eq('bad event name refused', /Unknown voice event/.test((await err(`select bot_voice_event($1, $2, 'voice_party')`, [vc, alice]))?.message ?? ''), true);

  await h.q(`update feature_flags set mode = 'everyone', servers = '{}' where key = 'bot_voice'`);
  h.eq('flag on for everyone: other server works too', await event(otherVc, alice, 'voice_join'), 1);
  h.eq('gate on for everyone', await gate(botC, other), null);

  // ---- service role only ----
  await h.as(owner);
  h.eq('members cannot call bot_voice_event', !!(await err(`select bot_voice_event($1, $2, 'voice_join')`, [vc, alice])), true);
  h.eq('members cannot call bot_voice_gate', !!(await err(`select bot_voice_gate($1, $2, true)`, [botA, sid])), true);
  h.eq('members cannot read bot_voice_rate', !!(await err(`select * from bot_voice_rate`)), true);
  await h.as(null);
  h.eq('anon cannot call bot_voice_event', !!(await err(`select bot_voice_event($1, $2, 'voice_join')`, [vc, alice])), true);
  h.eq('anon cannot call bot_voice_gate', !!(await err(`select bot_voice_gate($1, $2, false)`, [botA, sid])), true);
  await h.admin();
  h.eq('both are security definer with search_path set', (await h.q(`select proname, prosecdef, proconfig from pg_proc where proname in ('bot_voice_gate', 'bot_voice_event') order by proname`)).map((r) => [r.proname, r.prosecdef, r.proconfig]),
    [['bot_voice_event', true, ['search_path=public']], ['bot_voice_gate', true, ['search_path=public']]]);

  // Deleting a bot takes its rate row with it.
  await h.q(`delete from bots where id = $1`, [botA]);
  h.eq('rate row goes with the bot', (await h.one(`select count(*)::int n from bot_voice_rate where bot_id = $1`, [botA])).n, 0);
}
