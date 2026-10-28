// 615: lobby v2 part 2. servers.lobby_on (off by default) switched by managers only; lobby_extras gives members the
// Levels bot top 10 (current members, not site-banned, only with the bot on) and live giveaways in channels they can
// open; set_server_lobby_v2 takes the two new sections. Starts from stage 24 with the 533 stand-ins plus the bot tables.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('615_lobby_on_extras.sql');

const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists ticket_by uuid;
alter table public.channels add column if not exists private boolean not null default false;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create or replace function public.has_slur(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badword%' $$;
create or replace function public.has_sexual_spam(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%spamword%' $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badsite.com%' $$;
create table if not exists public.audit_seen (sid uuid, act text, actor uuid, extra jsonb);
create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
 returns void language sql security definer set search_path = public as $$ insert into public.audit_seen values (sid, act, auth.uid(), extra) $$;
create table if not exists public.server_bots (server_id uuid, bot text, enabled boolean, config jsonb default '{}');
create table if not exists public.server_xp (server_id uuid, user_id uuid, xp int, level int, last_at timestamptz default now(), primary key (server_id, user_id));
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.servers add column if not exists shut_down_at timestamptz;
create or replace function public.is_staff() returns boolean language sql stable as $$ select false $$;
create table if not exists public.giveaways (id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid, message_id uuid,
  host_id uuid, prize text, winners int default 1, ends_at timestamptz, ended_at timestamptz, winner_ids uuid[], plus_months int);
-- Stand-in: private channels are closed to everyone but the owner.
create or replace function public.can_access_channel(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.channels c join public.servers s on s.id = c.server_id
    where c.id = cid and public.is_server_member(c.server_id) and (not c.private or s.owner_id = auth.uid()));
$$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`615 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('533_server_lobby.sql'));
  await h.db.exec(mig('602_lobby_v2.sql'));
  await h.ok('615 runs', () => h.db.exec(MIG));
  await h.ok('615 re-runs cleanly', () => h.db.exec(MIG));

  const owner = await h.signup('o@x.com', 'owner');
  const member = await h.signup('p@x.com', 'plain');
  const left = await h.signup('l@x.com', 'left');
  const banned = await h.signup('b@x.com', 'banned');
  const outsider = await h.signup('x@x.com', 'outsider');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  for (const u of [owner, member, banned]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  h.eq('lobby off by default', (await h.one(`select lobby_on from servers where id = $1`, [S])).lobby_on, false);
  const chan = async (name, priv = false) => (await h.one(`insert into channels (server_id, name, kind, private) values ($1, $2, 'text', $3) returning id`, [S, name, priv])).id;
  const open = await chan('giveaways');
  const secret = await chan('mods', true);

  // Switching it on.
  const setOn = `select public.set_server_lobby_on($1, $2)`;
  await h.as(owner);
  await h.fails('refused while lobby_v2 is off for the server', setOn, [S, true]);
  await h.admin();
  await h.q(`update feature_flags set servers = array_append(servers, $1) where key in ('lobby_v2', 'server_lobby')`, [S]);
  await h.as(member);
  await h.fails('plain member cannot switch it on', setOn, [S, true]);
  await h.as(outsider);
  await h.fails('outsider cannot switch it on', setOn, [S, true]);
  await h.as(owner);
  await h.ok('owner switches it on', () => h.q(setOn, [S, true]));
  await h.admin();
  h.eq('on', (await h.one(`select lobby_on from servers where id = $1`, [S])).lobby_on, true);
  await h.as(owner);
  await h.ok('switching on again is a no-op', () => h.q(setOn, [S, true]));
  await h.admin();
  h.eq('one audit entry per real change', (await h.q(`select 1 from audit_seen where sid = $1 and extra ? 'lobby_on'`, [S])).length, 1);
  await h.as(owner);
  await h.ok('owner switches it off', () => h.q(setOn, [S, false]));

  // Extras.
  await h.admin();
  for (const [u, xp] of [[owner, 500], [member, 900], [left, 5000], [banned, 7000]]) {
    await h.q(`insert into server_xp (server_id, user_id, xp, level) values ($1, $2, $3, $4)`, [S, u, xp, Math.floor(xp / 100)]);
  }
  await h.q(`insert into site_bans (user_id, expires_at) values ($1, null)`, [banned]);
  await h.q(`insert into giveaways (server_id, channel_id, prize, ends_at) values ($1, $2, 'Nitro', now() + interval '1 day'), ($1, $2, 'Old', now() - interval '1 day'), ($1, $3, 'Secret', now() + interval '1 day')`, [S, open, secret]);
  await h.q(`insert into giveaways (server_id, channel_id, prize, ends_at, ended_at) values ($1, $2, 'Done', now() + interval '1 day', now())`, [S, open]);
  const extras = async (who) => { await h.as(who); return (await h.one(`select public.lobby_extras($1) as e`, [S])).e; };

  let e = await extras(member);
  h.eq('no leaderboard while the Levels bot is off', e.leaderboard, []);
  h.eq('live giveaways only, in channels I can open', e.giveaways.map((g) => g.prize), ['Nitro']);
  await h.admin();
  await h.q(`insert into server_bots (server_id, bot, enabled) values ($1, 'levels', true)`, [S]);
  e = await extras(member);
  h.eq('leaderboard: current, unbanned members by xp', e.leaderboard.map((r) => r.user_id), [member, owner]);
  h.eq('leaderboard rows carry xp and level', [e.leaderboard[0].xp, e.leaderboard[0].level], [900, 9]);
  e = await extras(owner);
  h.eq('owner sees the private channel giveaway too', e.giveaways.map((g) => g.prize).sort(), ['Nitro', 'Secret']);
  h.eq('outsider gets nothing', await extras(outsider), null);
  await h.admin();
  await h.q(`update servers set shut_down_at = now() where id = $1`, [S]);
  h.eq('shut-down server: nothing', await extras(member), null);
  await h.admin();
  await h.q(`update servers set shut_down_at = null where id = $1`, [S]);
  await h.q(`insert into site_bans (user_id) values ($1)`, [member]);
  h.eq('site-banned member: nothing', await extras(member), null);
  await h.as(null);
  await h.fails('logged out refused', `select public.lobby_extras($1)`, [S]);

  // New sections are accepted.
  await h.as(owner);
  await h.ok('v2 save with leaderboard and giveaways sections', () => h.q(
    `select public.set_server_lobby_v2($1, 'Hi', '[]'::jsonb, '{}'::uuid[], true, '{}'::jsonb, $2::jsonb)`,
    [S, JSON.stringify([{ id: 'leaderboard', on: true }, { id: 'giveaways', on: false }])]));
  await h.as(owner);
  await h.fails('still refuses unknown sections', `select public.set_server_lobby_v2($1, 'Hi', '[]'::jsonb, '{}'::uuid[], true, '{}'::jsonb, '[{"id":"ads","on":true}]'::jsonb)`, [S]);
}
