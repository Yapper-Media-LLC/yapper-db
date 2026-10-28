// 385: bot server counts only count real servers (not shut down, 3+ people who aren't bots), cached in bots.real_servers
// and refreshed by refresh_bot_real_servers(); bot_add_to_server allows 5 different servers a day for bots you don't
// own; making servers stops at 10 a day. Starts from stage 24 + flags (031, 041) with stand-ins for the live bot tables.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '385_real_bot_server_counts.sql'), 'utf8');

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.servers add column if not exists shut_down_at timestamptz;
create table if not exists public.bots (
  id uuid primary key references public.profiles(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null, description text not null default '', public boolean not null default false,
  verified_at timestamptz, unlisted boolean not null default false, shareable boolean not null default false,
  category text, tag text, avatar_path text, support_invite text, posts bigint not null default 0,
  submitted_at timestamptz, created_at timestamptz not null default now(),
  last_poll_at timestamptz, last_event_at timestamptz, last_used_at timestamptz
);
revoke all on public.bots from anon, authenticated;
grant select (id, name) on public.bots to authenticated;
create table if not exists public.bot_servers (
  bot_id uuid not null references public.bots(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  added_by uuid, added_at timestamptz not null default now(),
  primary key (bot_id, server_id)
);
create table if not exists public.bot_commands (bot_id uuid, name text, description text);
create table if not exists public.bot_accounts (user_id uuid primary key, bot text not null default 'x');
create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bots b where b.id = uid) or exists (select 1 from public.bot_accounts a where a.user_id = uid) $$;
create or replace function public.can_review_bots() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() $$;
insert into public.feature_flags (key, label, description, mode) values
  ('bot_api', 'Bot API', 'Bots', 'everyone'), ('bot_verified', 'Verified bots', 'Bots', 'everyone')
on conflict (key) do update set mode = 'everyone';
`;

export default async function (h) {
  const refused = async (sql, params, re) => {
    let msg = null;
    try { await h.q(sql, params); } catch (e) { msg = e.message; }
    if (!msg || !re.test(msg)) throw new Error(`expected ${re}, got ${msg ?? 'success'}`);
  };
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('385 re-runs cleanly', () => h.db.exec(MIG));

  const u = {};
  for (const n of ['maker', 'farmer', 'p1', 'p2', 'p3', 'p4', 'builder', 'boss']) u[n] = await h.signup(`${n}@t385.dev`, `${n}385`);
  const bot = await h.signup('bot@t385.dev', 'growbot');
  const bot2 = await h.signup('bot2@t385.dev', 'farmbot');
  const qbot = await h.signup('qbot@t385.dev', 'queuebot');
  const other = await h.signup('other@t385.dev', 'otherbot');
  const acct = await h.signup('acct@t385.dev', 'botacct');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [u.boss]);
  await h.q(`insert into bots (id, owner_id, name, public, verified_at) values
    ($1, $5, 'growbot', true, now()), ($2, $5, 'farmbot', true, now()), ($3, $5, 'queuebot', true, null), ($4, $5, 'otherbot', false, null)`,
    [bot, bot2, qbot, other, u.maker]);
  await h.q(`insert into bot_accounts (user_id) values ($1)`, [acct]);

  // Servers: real (3 people), farm (owner only), bot-padded (2 people + bot + bot account), shut down (3 people), maker's own real one.
  const mk = async (who, name) => { await h.as(who); return (await h.one(`select create_server($1, null) id`, [name])).id; };
  const real = await mk(u.p1, 'Real');
  const farm = await mk(u.farmer, 'Farm');
  const padded = await mk(u.p2, 'Padded');
  const dead = await mk(u.p3, 'Dead');
  const mine = await mk(u.maker, 'Mine');
  await h.admin();
  const join = (sid, ...ids) => Promise.all(ids.map((id) => h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, id])));
  await join(real, u.p2, u.p3);
  await join(padded, u.p3, other, acct);
  await join(dead, u.p1, u.p2);
  await join(mine, u.p1, u.p2);
  await h.q(`update servers set shut_down_at = now() where id = $1`, [dead]);
  for (const s of [real, farm, padded, dead, mine]) {
    await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $2)`, [bot, s]);
    await join(s, bot);
  }
  // farmbot: in 4 farm-like servers, only 0 real
  for (let i = 0; i < 4; i++) {
    const s = await mk(u.p4, `F${i}`);
    await h.admin();
    await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $2)`, [bot2, s]);
  }
  await h.admin();
  await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $2)`, [bot2, real]);

  h.eq('real servers: Real + Mine', (await h.q(`select server_id from bot_real_servers($1) order by server_id`, [bot])).map((r) => r.server_id), [real, mine].sort());
  h.eq('bot_real_server_count', (await h.one(`select bot_real_server_count($1)::int n`, [bot])).n, 2);

  // Migration's own refresh ran before the data existed; set cache back to null to test the live fallback.
  await h.q(`update bots set real_servers = null`);
  await h.as(u.p1);
  let dir = await h.q(`select name, servers::int from bot_directory('', '', 'popular')`);
  h.eq('directory counts real servers live when not cached, popular sorts by real', dir, [{ name: 'growbot', servers: 2 }, { name: 'farmbot', servers: 1 }]);
  h.eq('public_bots too', (await h.q(`select name, servers::int from public_bots()`)), [{ name: 'growbot', servers: 2 }, { name: 'farmbot', servers: 1 }]);
  h.eq('community_bots too', (await h.q(`select name, servers::int from community_bots()`)), [{ name: 'growbot', servers: 2 }, { name: 'farmbot', servers: 1 }]);

  await h.admin();
  await h.one(`select refresh_bot_real_servers()`);
  h.eq('cache filled for listed and queued bots only', await h.q(`select name, real_servers from bots order by name`),
    [{ name: 'farmbot', real_servers: 1 }, { name: 'growbot', real_servers: 2 }, { name: 'otherbot', real_servers: null }, { name: 'queuebot', real_servers: 0 }]);
  // A farm server gets real people: the cache shows the old number until the next refresh.
  await join(farm, u.p1, u.p2);
  await h.as(u.p1);
  h.eq('directory reads the cache', (await h.one(`select servers::int n from bot_directory('', '', 'popular') where name = 'growbot'`)).n, 2);
  await h.admin();
  h.eq('refresh reports changed rows', (await h.one(`select refresh_bot_real_servers() n`)).n, 1);
  await h.as(u.p1);
  h.eq('after refresh', (await h.one(`select servers::int n from public_bots() where name = 'growbot'`)).n, 3);
  await h.admin();
  await h.q(`update bots set public = false, verified_at = null where id = $1`, [bot2]);
  await h.one(`select refresh_bot_real_servers()`);
  h.eq('cache cleared when a bot leaves the directory', (await h.one(`select real_servers from bots where id = $1`, [bot2])).real_servers, null);

  // Maker's checklist keeps "not your own servers".
  await h.as(u.maker);
  const vp = (await h.one(`select bot_verify_progress($1) p`, [bot])).p;
  h.eq('verify progress: total and real minus own', [vp.servers, vp.real_servers], [5, 2]);

  // Staff queue: total and real.
  await h.admin();
  await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $2), ($1, $3)`, [qbot, real, padded]);
  await h.as(u.boss);
  h.eq('review queue shows real / total', await h.q(`select name, servers::int, real_servers::int from bot_review_queue()`), [{ name: 'queuebot', servers: 2, real_servers: 1 }]);

  // Internals are not callable by users.
  await h.as(u.p1);
  await h.fails('users cannot call bot_real_servers', `select * from bot_real_servers($1)`, [bot]);
  await h.fails('users cannot call refresh', `select refresh_bot_real_servers()`);

  // ---- anti-farming: adding bots ----
  await h.as(u.builder);
  const bs = [];
  for (let i = 0; i < 7; i++) bs.push((await h.one(`select create_server($1, null) id`, [`B${i}`])).id);
  for (let i = 0; i < 5; i++) await h.ok(`add to server ${i + 1}`, () => h.q(`select bot_add_to_server($1, $2)`, [bot, bs[i]]));
  await h.ok('6th server in a day is refused', () => refused(`select bot_add_to_server($1, $2)`, [bot, bs[5]], /5 servers today/));
  await h.admin();
  await h.q(`update bots set public = true, verified_at = now() where id = $1`, [bot2]);
  await h.as(u.builder);
  await h.ok('another bot into a server already counted today is fine', () => h.q(`select bot_add_to_server($1, $2)`, [bot2, bs[0]]));
  await h.ok('re-adding where it already is is fine', () => h.q(`select bot_add_to_server($1, $2)`, [bot, bs[1]]));
  await h.admin();
  await h.q(`update bot_servers set added_at = now() - interval '25 hours' where added_by = $1`, [u.builder]);
  await h.as(u.builder);
  await h.ok('a day later it works again', () => h.q(`select bot_add_to_server($1, $2)`, [bot, bs[5]]));
  // Owners adding their own bot are not limited.
  await h.as(u.maker);
  const own = [];
  for (let i = 0; i < 7; i++) own.push((await h.one(`select create_server($1, null) id`, [`O${i}`])).id);
  await h.ok('maker adds own bot to 7 servers', async () => { for (const s of own) await h.q(`select bot_add_to_server($1, $2)`, [bot, s]); });

  // ---- anti-farming: making servers ----
  await h.as(u.farmer);
  // farmer made 1 already (Farm)
  for (let i = 0; i < 9; i++) await h.q(`select create_server($1, null)`, [`X${i}`]);
  await h.ok('11th server in a day is refused', () => refused(`select create_server('X10', null)`, [], /10 servers a day/));
  await h.admin();
  await h.q(`update servers set created_at = now() - interval '25 hours' where owner_id = $1`, [u.farmer]);
  await h.as(u.farmer);
  await h.ok('a day later it works again', () => h.q(`select create_server('X11', null)`));
  await h.as(u.boss);
  await h.ok('site admins are not limited', async () => { for (let i = 0; i < 11; i++) await h.q(`select create_server($1, null)`, [`A${i}`]); });
  await h.admin();
  await h.ok('service inserts (no signed-in user) are not limited', async () => {
    for (let i = 0; i < 11; i++) await h.q(`insert into servers (name, owner_id) values ($1, $2)`, [`S${i}`, u.farmer]);
  });
}
