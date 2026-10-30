// 628: the online window follows the 5 minute heartbeat (rt_presence on for everyone). 001..024, then stand-ins for
// the live pieces 628 touches (presence and online_time as stage263, bots / bot_accounts, the servers banner columns,
// a search_people with the two window lines and a here_targets with one), then 628 twice (re-runnable).
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
create table if not exists public.bots (id uuid primary key, presence jsonb);
create table if not exists public.bot_accounts (user_id uuid primary key);
alter table public.servers add column if not exists banner_path text, add column if not exists banner_x int, add column if not exists banner_y int, add column if not exists banner_zoom real;
create or replace function public.search_people(q text) returns int language sql stable as $$
  select count(*)::int from public.presence pr where pr.last_seen > now() - interval '100 seconds'
  union all select count(*)::int from public.presence pr where pr.last_seen > now() - interval '100 seconds' limit 1 $$;
create or replace function public.here_targets(cid uuid, sid uuid, author uuid, cp boolean) returns uuid[] language sql stable as $$
  select coalesce(array_agg(p.user_id), '{}') from public.presence p where p.last_seen > now() - interval '100 seconds' $$;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '628_presence_window.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('628 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy628@test.dev', 'amy628');
  const bob = await h.signup('bob628@test.dev', 'bob628');
  const cat = await h.signup('cat628@test.dev', 'cat628');
  const bot = await h.signup('bot628@test.dev', 'bot628');
  await h.admin();
  h.eq('window is 7 minutes', (await h.one(`select extract(epoch from presence_ttl())::int s`)).s, 420);
  const patched = async (f) => (await h.one(`select pg_get_functiondef($1::regprocedure) d`, [f])).d;
  h.eq('search_people patched', (await patched('public.search_people(text)')).includes('100 seconds'), false);
  h.eq('search_people uses the window', (await patched('public.search_people(text)')).split('presence_ttl()').length, 3);
  h.eq('here_targets patched', (await patched('public.here_targets(uuid,uuid,uuid,boolean)')).includes('presence_ttl()'), true);

  // Beats 5 min 40 s apart (the slow heartbeat on a throttled tab) keep you online; 8 minutes without one does not.
  await h.q(`insert into bots (id) values ($1)`, [bot]);
  await h.q(`insert into presence (user_id, status, last_seen, online_since, status_at) values
    ($1, 'online', now() - interval '340 seconds', now() - interval '1 hour', now() - interval '1 hour'),
    ($2, 'online', now() - interval '8 minutes', now() - interval '1 hour', now() - interval '1 hour'),
    ($3, 'online', now() - interval '10 seconds', now() - interval '1 hour', now() - interval '1 hour'),
    ($4, 'online', now(), now(), now())`, [amy, bob, cat, bot]);
  await h.as(null);
  h.eq('online_count: amy and cat, not bob (8 min) or the bot', (await h.one(`select online_count() n`)).n, 2);
  await h.admin();
  const srv = (await h.one(`insert into servers (name, owner_id) values ('s628', $1) returning id`, [cat])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4)`, [srv, amy, bob, cat]);
  await h.q(`insert into invites (code, server_id, created_by) values ('inv628ab', $1, $2)`, [srv, cat]);
  await h.as(null);
  const card = (await h.one(`select invite_card('inv628ab') c`)).c;
  h.eq('invite card: 3 members, 2 online', [card.member_count, card.online_count], [3, 2]);

  // who_online: a full look lists amy and cat; a delta since 5 minutes ago says bob went away and nothing about amy
  // (her 340 s old beat is still inside the window, so she isn't "changed" either).
  await h.as(cat);
  const rows = async (since) => (await h.one(`select who_online(null, array[$1, $2]::uuid[], $3::timestamptz) r`, [amy, bob, since])).r.rows;
  h.eq('full poll lists amy', (await rows(null)).map((r) => r[0]), [amy]);
  h.eq('delta poll: bob gone, amy unchanged', await rows(new Date(Date.now() - 300_000).toISOString()), [[bob, 'off', null]]);
  h.eq('a 12 minute late delta poll still reports bob as gone', await rows(new Date(Date.now() - 720_000).toISOString()), [[bob, 'off', null]]);

  // A beat 340 s after the last one keeps online_since and counts the whole gap as time online (was capped at 60 s).
  await h.as(amy);
  await h.q(`select heartbeat('online', null)`);
  await h.admin();
  const p = await h.one(`select extract(epoch from (now() - online_since))::int since, (select secs from online_time where user_id = $1 and day = current_date) secs from presence where user_id = $1`, [amy]);
  h.eq('online_since kept across a 5 minute beat', p.since > 3000, true);
  h.eq('online_time counts the 340 s gap', p.secs >= 339 && p.secs <= 341, true);
  // After the window, a beat starts a new online_since and counts no time.
  await h.as(bob);
  await h.q(`select heartbeat('online', null)`);
  await h.admin();
  const pb = await h.one(`select extract(epoch from (now() - online_since))::int since, (select secs from online_time where user_id = $1 and day = current_date) secs from presence where user_id = $1`, [bob]);
  h.eq('online_since restarts after 8 minutes away', pb.since < 5, true);
  h.eq('no online_time after 8 minutes away', pb.secs ?? null, null);

  // Invisible or closing the tab drops you out of every count at once, not after the window.
  await h.as(amy);
  await h.q(`select heartbeat('off', null)`);
  await h.as(null);
  h.eq('off: amy drops out right away', (await h.one(`select online_count() n`)).n, 2); // bob (just beat) and cat
  await h.as(cat);
  h.eq('off: who_online says amy left', (await rows(new Date(Date.now() - 60_000).toISOString())).filter((r) => r[0] === amy), [[amy, 'off', null]]);

  // A bot's beat keeps its online_since across a 5 minute gap too.
  await h.admin();
  await h.q(`update presence set last_seen = now() - interval '340 seconds', online_since = now() - interval '1 hour' where user_id = $1`, [bot]);
  await h.q(`select bot_presence($1, null, null)`, [bot]);
  h.eq('bot online_since kept', (await h.one(`select extract(epoch from (now() - online_since))::int s from presence where user_id = $1`, [bot])).s > 3000, true);
}
