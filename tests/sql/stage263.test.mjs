// 263: presence fixes and pings. 001..024, then stand-ins for live pieces 263 touches (as live, Oct 18): the presence
// and online_time tables (058, 074, 099, 102), channels.category_id + channel_overrides (142), and bc() logging what it
// would publish. Then 263 twice (re-runnable).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
create table if not exists public.presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  status text not null default 'online' check (status in ('online', 'idle', 'dnd')),
  last_seen timestamptz not null default now(),
  online_since timestamptz not null default now(),
  status_at timestamptz not null default now(),
  activity jsonb, activity_at timestamptz, pref text
);
alter table public.presence enable row level security;
create table if not exists public.online_time (user_id uuid not null, day date not null, secs int not null default 0, primary key (user_id, day));
alter table public.channels add column if not exists category_id uuid;
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create table public.rt_log (topic text, op text, msg uuid, sub text);
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.rt_log values (topic_name, operation, case when operation = 'DELETE' then null else (to_jsonb(new) ->> 'id')::uuid end,
    current_setting('request.jwt.claim.sub', true));
end $$;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '263_presence_and_pings.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('263 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');

  // Idle picked on the account wins over "online" from a tab that hasn't caught up.
  await h.admin();
  await h.q(`insert into presence (user_id, status, pref) values ($1, 'online', 'idle')`, [amy]);
  await h.as(amy);
  await h.q(`select heartbeat('online', null)`);
  await h.admin();
  h.eq('pref idle turns online into idle', (await h.one(`select status from presence where user_id = $1`, [amy])).status, 'idle');
  await h.as(amy);
  await h.q(`select heartbeat('dnd', null)`);
  await h.admin();
  h.eq('pref idle leaves dnd alone', (await h.one(`select status from presence where user_id = $1`, [amy])).status, 'dnd');

  // who_online: bob went offline 4 minutes ago (last beat 5 min 40 s ago); the last poll was 5 minutes ago.
  // The old 200 s window missed him, so he stayed green.
  await h.q(`insert into presence (user_id, status, last_seen, online_since, status_at) values ($1, 'online', now() - interval '340 seconds', now() - interval '1 hour', now() - interval '1 hour')`, [bob]);
  await h.q(`insert into presence (user_id, status, last_seen, online_since, status_at) values ($1, 'online', now(), now() - interval '1 hour', now() - interval '1 hour')`, [cat]);
  await h.as(amy);
  const rows = async (since) => (await h.one(`select who_online(null, array[$1, $2]::uuid[], $3::timestamptz) r`, [bob, cat, since])).r.rows;
  const delta = await rows(new Date(Date.now() - 300_000).toISOString());
  h.eq('a late delta poll still reports bob as gone', delta, [[bob, 'off', null]]);
  const full = await rows(null);
  h.eq('a full poll lists only who is online', full.map((r) => r[0]), [cat]);
  const quick = await rows(new Date(Date.now() - 75_000).toISOString());
  h.eq('a normal 75 s delta has nothing new', quick, []);
  await h.as(null);
  await h.fails('signed out: not allowed', `select who_online(null, array[$1]::uuid[], null)`, [cat]);

  // ---------- pings ----------
  await h.admin();
  await h.q(`drop trigger if exists messages_broadcast on public.messages`);
  await h.q(`create trigger messages_broadcast after insert or update or delete on public.messages for each row execute function public.broadcast_message_change()`);
  // Only this trigger: the early migrations' rate limits and checks aren't what's tested here.
  await h.q(`alter table public.messages disable trigger user`);
  await h.q(`alter table public.messages enable trigger messages_broadcast`);
  const dan = await h.signup('dan@test.dev', 'dan');
  const eve = await h.signup('eve@test.dev', 'eve'); // not in the server
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  for (const u of [amy, bob, cat, dan]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u]);
  const pub = (await h.one(`insert into channels (server_id, kind, name) values ($1, 'text', 'general') returning id`, [sid])).id;
  const priv = (await h.one(`insert into channels (server_id, kind, name, private) values ($1, 'text', 'secret', true) returning id`, [sid])).id;
  const role = (await h.one(`insert into roles (server_id, name) values ($1, 'mods') returning id`, [sid])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3), ($1, $4, $3)`, [sid, cat, role, dan]);
  await h.q(`insert into channel_roles (server_id, channel_id, role_id) values ($1, $2, $3)`, [sid, priv, role]);

  let n = 0;
  const send = async (who, cid, content, reply = null) => {
    await h.admin();
    await h.q(`truncate rt_log`);
    await h.as(who);
    const id = (await h.one(`insert into messages (channel_id, author_id, content, reply_to_id, created_at) values ($1, $2, $3, $4, now() + ($5 || ' ms')::interval) returning id`, [cid, who, content, reply, String(n++)])).id;
    await h.admin();
    return id;
  };
  const pinged = async () => (await h.q(`select topic from rt_log where topic like 'user:%' order by topic`)).map((r) => r.topic.slice(5));
  const sorted = (a) => [...a].sort();

  const hello = await send(amy, pub, `hi <@${bob}> and <@${eve}>`);
  h.eq('@bob pings bob, not someone outside the server', await pinged(), [bob]);
  h.eq('the channel topic still gets it', (await h.q(`select count(*)::int n from rt_log where topic = $1`, [`chan:${pub}`]))[0].n, 1);
  h.eq('the sender is themselves again for later triggers', (await h.q(`select distinct sub from rt_log`)).map((r) => r.sub), [amy]);
  await send(bob, pub, 'yo', hello);
  h.eq('a reply pings the person replied to', await pinged(), [amy]);
  await send(amy, pub, `<@&${role}> look`);
  h.eq('a role ping reaches everyone with the role', await pinged(), sorted([cat, dan]));
  await send(cat, priv, `<@${bob}> <@${dan}> secret`);
  h.eq('a private channel only pings people who can see it', await pinged(), [dan]);
  h.eq('asked as each person, then the sender again', (await h.q(`select distinct sub from rt_log`)).map((r) => r.sub), [cat]);
  await send(amy, pub, '\u21aa Forwarded\n<@' + bob + '>');
  h.eq('a forward pings nobody', await pinged(), []);
  await send(amy, pub, '<@------------------------------------> still sends');
  h.eq('a fake id neither fails nor pings', await pinged(), []);
  await send(bob, pub, `me <@${bob}>`);
  h.eq('pinging yourself does nothing', await pinged(), []);
}
