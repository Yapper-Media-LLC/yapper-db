// 221: bug fixes. Deleting a server takes its tag off wearers; custom links need 5 people (not bots); kicking a
// built-in bot turns it off; reorder_channels only touches moved channels; the log-out-everywhere signal.
// Runs on stage 24 plus stand-ins for the later bits it touches.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
alter table public.profiles add column if not exists server_tag uuid references public.servers(id) on delete set null;
alter table public.profiles add column if not exists tag text;
alter table public.channels add column if not exists position int not null default 0;
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (bot text primary key, user_id uuid);
create table if not exists public.server_bots (server_id uuid, bot text, enabled boolean default true, config jsonb, primary key (server_id, bot));
alter table public.invites add column if not exists vanity boolean not null default false;
create table if not exists public.vanity_changes (server_id uuid, user_id uuid, at timestamptz default now());
create table if not exists public.bc_log (topic text, event text, rec jsonb);
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
  returns void language plpgsql security definer set search_path = public
  as $$ begin insert into public.bc_log values (topic_name, event_name, to_jsonb(new)); end $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.outranks(sid uuid, target uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.lookalike_key(t text) returns text language sql immutable as $$ select lower(t) $$;
create or replace function public.vanity_key(t text) returns text language sql immutable as $$ select lower(t) $$;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.brand_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.vanity_reserved(t text) returns boolean language sql immutable as $$ select false $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '221_bug_fixes.sql'), 'utf8');
  await h.db.exec(sql);
  await h.ok('migration runs twice', () => h.db.exec(sql));

  const owner = await h.signup('o@x.com', 'owner');
  const wearer = await h.signup('w@x.com', 'wearer');
  const others = [];
  for (let i = 0; i < 3; i++) others.push(await h.signup(`p${i}@x.com`, `person${i}`));
  const botUser = await h.signup('bot@x.com', 'welcomer');
  await h.admin();
  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  for (const u of [owner, wearer, ...others]) await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u]);

  // 1. Tag text goes when the server is deleted.
  const sid2 = (await h.one(`insert into public.servers (name, owner_id) values ('Gone', $1) returning id`, [owner])).id;
  await h.q(`update public.profiles set server_tag = $1, tag = 'GONE' where id = $2`, [sid2, wearer]);
  await h.q(`del` + `ete from public.servers where id = $1`, [sid2]);
  const w = await h.one(`select server_tag, tag from public.profiles where id = $1`, [wearer]);
  h.eq('deleted server: tag id cleared', w.server_tag, null);
  h.eq('deleted server: tag text cleared', w.tag, null);

  // 2. Custom link: 5 people, bots don't count.
  await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, botUser]);
  await h.q(`insert into public.bot_accounts (bot, user_id) values ('welcomer', $1)`, [botUser]);
  await h.q(`insert into public.server_bots (server_id, bot) values ($1, 'welcomer')`, [sid]);
  await h.q(`del` + `ete from public.server_members where server_id = $1 and user_id = $2`, [sid, others[2]]);
  await h.as(owner);
  await h.fails('4 people + a bot is not enough for a custom link', `select public.set_vanity_invite($1, 'coolplace')`, [sid]);
  await h.admin();
  await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2)`, [sid, others[2]]);
  await h.as(owner);
  await h.ok('5 people unlock it', () => h.q(`select public.set_vanity_invite($1, 'coolplace')`, [sid]));

  // 3. Kicking the built-in bot turns it off.
  await h.ok('kick the bot', () => h.q(`select public.kick_member($1, $2)`, [sid, botUser]));
  await h.admin();
  h.eq('bot turned off in that server', (await h.one(`select enabled from public.server_bots where server_id = $1 and bot = 'welcomer'`, [sid])).enabled, false);

  // 4. Reorder only writes channels that move.
  const ch = [];
  for (let i = 0; i < 3; i++) ch.push((await h.one(`insert into public.channels (server_id, name, kind, position) values ($1, $2, 'text', $3) returning id`, [sid, `c${i}`, i])).id);
  await h.as(owner);
  await h.ok('reorder', () => h.q(`select public.reorder_channels($1, $2::uuid[])`, [sid, [ch[2], ch[0], ch[1]]]));
  await h.admin();
  const pos = (await h.q(`select id, position from public.channels where id = any($1::uuid[])`, [ch])).reduce((m, r) => ({ ...m, [r.id]: r.position }), {});
  h.eq('new order saved', [pos[ch[2]], pos[ch[0]], pos[ch[1]]], [0, 1, 2]);
  await h.as(wearer);
  await h.fails('non-managers cannot reorder', `select public.reorder_channels($1, $2::uuid[])`, [sid, [ch[0], ch[1], ch[2]]]);

  // 5. Log out everywhere: one signal on my own topic.
  await h.as(wearer);
  await h.ok('signal', () => h.q(`select public.logout_everywhere_signal()`));
  await h.admin();
  const sig = await h.one(`select topic, event, rec from public.bc_log where event = 'logout_all'`);
  h.eq('signal goes to my own topic', sig.topic, `user:${wearer}`);
  h.eq('signal names me', sig.rec.user_id, wearer);
  await h.as(null);
  await h.fails('logged out users cannot call it', `select public.logout_everywhere_signal()`);
}
