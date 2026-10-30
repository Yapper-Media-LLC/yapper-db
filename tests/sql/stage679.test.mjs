// 679: Global leaderboards (flag global_leaderboards). Base 24 + the flag functions (031/041), stand-ins for the live
// shapes 679 reads (messages webhook / system, profiles badges / leaderboard_hidden, site_bans.expires_at, bots,
// bot_accounts, shard_ledger, plus_gifts, referrals), then 679 twice (re-runnable).
// Checks: it refuses to run without messages_created_idx, the first tick starts the counters and the backfill job
// counts history once (bots and the webhook account skipped), later ticks count new messages only (no webhook or
// system messages), weekly counters reset lazily in a new week, Shards earned counts earning kinds only, voice is wall
// clock per person (two connections count once, the last leave credits the rest, a leave before its join blocks it,
// a missed leave stops at 6 hours, flag off = nothing), gifts and invites (invitee came back on a later day) sync, boards skip hidden / bots / banned / excluded, ranks tie, your rank inside and outside the
// top 100, the flag gates the page, clients can't reach the tables or the tick, and the reads use their indexes.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '679_global_leaderboards.sql'), 'utf8');

const STANDINS = String.raw`
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists leaderboard_hidden boolean not null default false;
alter table public.feature_flags add column if not exists servers uuid[] not null default '{}';
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.messages add column if not exists webhook jsonb;
alter table public.messages add column if not exists system jsonb;
alter table public.app_settings add column if not exists webhook_user_id uuid;
create table if not exists public.shard_days (user_id uuid not null references public.profiles(id) on delete cascade, day date not null,
  minutes int not null default 0, primary key (user_id, day));
create table if not exists public.bots (id uuid primary key references public.profiles(id) on delete cascade);
create table if not exists public.bot_accounts (user_id uuid primary key references public.profiles(id) on delete cascade);
create table if not exists public.shard_ledger (id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade, amount int not null, kind text not null,
  created_at timestamptz not null default now());
create table if not exists public.plus_gifts (id uuid primary key default gen_random_uuid(),
  gifter_id uuid references public.profiles(id) on delete set null, recipient_id uuid references public.profiles(id),
  source text not null, refunded_at timestamptz);
create table if not exists public.referrals (invitee uuid primary key references public.profiles(id) on delete cascade,
  inviter uuid references public.profiles(id) on delete cascade, status text not null default 'pending',
  created_at timestamptz not null default now());
create index if not exists messages_author_created_idx on public.messages (author_id, created_at desc);
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`679 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  const ANTIC = '00000000-0000-4000-8000-00000000a001';
  const a = await h.signup('a@679.dev', 'a679');
  const b = await h.signup('b@679.dev', 'b679');
  const c = await h.signup('c@679.dev', 'c679');
  const bot = await h.signup('bot@679.dev', 'bot679');
  const banned = await h.signup('ban@679.dev', 'ban679');
  const hid = await h.signup('hid@679.dev', 'hid679');
  const staff = await h.signup('staff@679.dev', 'staff679');
  const hook = await h.signup('hook@679.dev', 'hook679');
  await h.admin();
  await h.db.exec(STANDINS);
  const ch = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'k679') returning id`)).id;
  // Raw inserts (triggers off) so created_at can be set.
  const send = async (uid, n, ago, extra = '') => {
    await h.db.exec(`set session_replication_role = replica`);
    await h.q(`insert into messages (channel_id, author_id, content, created_at${extra ? ', ' + extra.split('=')[0] : ''})
      select $1, $2, 'hi', now() - $4::interval${extra ? ', ' + extra.split('=')[1] : ''} from generate_series(1, $3)`, [ch, uid, n, ago]);
    await h.db.exec(`set session_replication_role = origin`);
  };
  // History (backfilled): a 5 old + 2 this week + a system message (history counts those), b 3, bot 50, the
  // webhook account 4.
  const intoWeek = (await h.one(`select extract(epoch from now() - date_trunc('week', now() at time zone 'utc') at time zone 'utc')::int s`)).s;
  await send(a, 5, '30 days');
  if (intoWeek > 3600) await send(a, 2, '30 minutes'); else await send(a, 2, '30 days');
  await send(b, 3, '40 days');
  await send(bot, 50, '1 day');
  await send(hook, 4, '1 day', `webhook='{}'::jsonb`);
  await h.q(`update app_settings set webhook_user_id = $1`, [hook]);
  await send(a, 1, '30 days', `system='{}'::jsonb`);
  await h.q(`insert into bots (id) values ($1)`, [bot]);

  await h.ok('679 refuses to run without messages_created_idx', async () => {
    try { await h.db.exec(MIG); } catch (e) { if (/messages_created_idx/.test(e.message)) return; throw e; }
    throw new Error('ran without the index');
  });
  await h.db.exec(`create index if not exists messages_created_idx on public.messages (created_at)`);
  await h.ok('679 runs', () => h.db.exec(MIG));
  await h.ok('679 re-runs cleanly', () => h.db.exec(MIG));
  const weekStart = (await h.one(`select public.lb_week(now()) w`)).w;
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'global_leaderboards'`);
  h.eq('flag test mode for HQ + Antic', [flag.mode, flag.servers, flag.users], ['test', ['00000000-0000-4000-8000-00000000b001'], [ANTIC]]);
  h.eq('state row seeded', (await h.one(`select count(*)::int n from leaderboard_state`)).n, 1);

  const stats = (u) => h.one(`select week, msgs_week, voice_week, shards_week, msgs_all::int msgs_all, gifts, invites from leaderboard_stats where user_id = $1`, [u]);
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('nothing before the backfill job', (await stats(a)), undefined);
  await h.q(`select public.refresh_leaderboards_backfill()`);
  const sa = await stats(a);
  h.eq('backfill: all of a, system line included', sa.msgs_all, 8);
  h.eq('backfill: this week part', sa.msgs_week, intoWeek > 3600 ? 2 : 0);
  h.eq('backfill: b', (await stats(b)).msgs_all, 3);
  h.eq('backfill skips bots', await stats(bot), undefined);
  h.eq('backfill skips the webhook account', await stats(hook), undefined);
  h.eq('backfill finished', (await h.one(`select backfill_done from leaderboard_state`)).backfill_done, true);
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('a second backfill run does nothing', (await h.one(`select public.refresh_leaderboards_backfill() n`)).n, 0);
  h.eq('a second tick counts nothing twice', (await stats(a)).msgs_all, 8);

  // New messages after the first pass: counted by the next tick, once they're 2 minutes old.
  await h.q(`update leaderboard_state set msgs_upto = now() - interval '10 minutes'`);
  await send(c, 4, '5 minutes');
  await send(a, 1, '30 seconds');           // too fresh: next tick
  await send(bot, 9, '5 minutes');
  await send(c, 2, '5 minutes', `webhook='{}'::jsonb`);
  await send(c, 1, '5 minutes', `system='{}'::jsonb`);
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('new messages counted', [(await stats(c)).msgs_all, (await stats(c)).msgs_week], intoWeek > 600 ? [4, 4] : [4, 0]);
  h.eq('fresh ones wait', (await stats(a)).msgs_all, 8);
  h.eq('bots still skipped', await stats(bot), undefined);

  // Lazy weekly reset: a row from an old week starts over; old-week data never lands in a newer week.
  await h.q(`update leaderboard_stats set week = week - 7, msgs_week = 99, voice_week = 99 where user_id = $1`, [b]);
  await h.q(`select public.lb_bump(array[$1::uuid], array[public.lb_week(now())], array[2], array[0], array[0], array[2::bigint])`, [b]);
  h.eq('new week resets the weekly counters', await stats(b), { week: weekStart, msgs_week: 2, voice_week: 0, shards_week: 0, msgs_all: 5, gifts: 0, invites: 0 });
  await h.q(`select public.lb_bump(array[$1::uuid], array[public.lb_week(now()) - 7], array[5], array[0], array[0], array[5::bigint])`, [b]);
  h.eq('late data for last week: all time only', [(await stats(b)).msgs_week, (await stats(b)).msgs_all], [2, 10]);

  // Shards: earning kinds only, ids after the watermark, 2 minutes old.
  await h.q(`insert into shard_ledger (user_id, amount, kind, created_at) values
    ($1, 10, 'daily', now() - interval '5 minutes'), ($1, 20, 'quest', now() - interval '5 minutes'),
    ($1, -100, 'level_up', now() - interval '5 minutes'), ($1, 50, 'deco_sale', now() - interval '5 minutes'),
    ($1, 7, 'activity', now() - interval '5 minutes'), ($2, 5, 'activity', now())`, [c, a]);
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('Shards earned: daily + quest + activity', (await stats(c)).shards_week, 37);
  h.eq('fresh ledger rows wait', (await stats(a)).shards_week, 0);
  await h.q(`update shard_ledger set created_at = now() - interval '5 minutes'`);
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('then counted once', [(await stats(a)).shards_week, (await stats(c)).shards_week], [5, 37]);

  // Voice.
  await h.as(a);
  await h.fails('users cannot post voice events', `select public.leaderboard_voice_event($1, 's1', 'join', now())`, [a]);
  await h.admin();
  const ve = async (u, sid, ev, ago = '0 seconds') => {
    await h.q(`set role service_role`);
    const r = (await h.one(`select public.leaderboard_voice_event($1, $2, $3, now() - $4::interval) s`, [u, sid, ev, ago])).s;
    await h.admin();
    return r;
  };
  const open = async () => (await h.one(`select count(*)::int n from leaderboard_voice_open where not closed`)).n;
  // b in voice on two devices for 20 minutes: counted once.
  await ve(b, 's1', 'join', '20 minutes');
  await ve(b, 's1', 'join', '20 minutes'); // replay
  await ve(b, 's2', 'join', '20 minutes');
  h.eq('two open connections', await open(), 2);
  await h.q(`select public.refresh_leaderboards()`);
  const v1 = (await stats(b)).voice_week;
  h.eq('a running call is credited by the tick, once for two devices', v1 >= Math.min(1200, intoWeek) - 2 && v1 <= 1202, true);
  await h.q(`update leaderboard_voice_open set since = since - interval '60 seconds'`); // as if 60 s went by
  h.eq('leaving one device credits nothing yet', await ve(b, 's1', 'leave'), 0);
  const left = await ve(b, 's2', 'leave');
  h.eq('the last leave credits what the tick did not', left >= 59 && left <= 62, true);
  h.eq('a second leave credits nothing', await ve(b, 's2', 'leave'), 0);
  // A leave that beats its join: the late join can't open a session nobody closes.
  await ve(c, 's9', 'leave');
  await ve(c, 's9', 'join', '5 seconds');
  h.eq('a leave before its join blocks the join', await open(), 0);
  // A missed leave: counts for 6 hours after the join at most, then the row goes.
  await ve(c, 's3', 'join', '20 hours');
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('a stale connection is capped at 6 h and closed', [await open(), (await stats(c)).voice_week], [0, Math.max(0, Math.min(6 * 3600, intoWeek - 14 * 3600))]);
  // Flag off: joins aren't tracked and the tick drops what's open.
  await ve(c, 's4', 'join', '1 minute');
  await h.q(`update feature_flags set mode = 'off' where key = 'global_leaderboards'`);
  await ve(c, 's5', 'join');
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('flag off: voice not tracked', (await h.one(`select count(*)::int n from leaderboard_voice_open`)).n, 0);
  await h.q(`update feature_flags set mode = 'test' where key = 'global_leaderboards'`);

  // Gifts and invites.
  await h.q(`insert into plus_gifts (gifter_id, recipient_id, source) values ($1, $2, 'stripe'), ($1, $2, 'stripe'), ($1, $2, 'giveaway'), ($2, $1, 'stripe')`, [c, a]);
  await h.q(`update plus_gifts set refunded_at = now() where gifter_id = $1`, [a]);
  await h.q(`insert into referrals (invitee, inviter, status, created_at) values ($1, $2, 'pending', now() - interval '3 days'),
    ($3, $2, 'refused', now() - interval '3 days'), ($4, $2, 'pending', now() - interval '3 days')`, [hid, a, staff, c]);
  // hid came back two days later; c (an invitee too) never did, staff was refused.
  await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - 1, 10), ($2, current_date - 3, 30), ($3, current_date - 1, 10)`, [hid, c, staff]);
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('gifts: paid, not refunded', [(await stats(c)).gifts, (await stats(a)).gifts], [2, 0]);
  h.eq('invites: not refused, came back on a later day', (await stats(a)).invites, 1);
  await h.q(`update referrals set status = 'refused' where inviter = $1`, [a]);
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('a refused invite drops off', (await stats(a)).invites, 0);

  // Boards: exclusions and ranks.
  await h.q(`insert into leaderboard_stats (user_id, msgs_all) values ($1, 1000), ($2, 1000), ($3, 1000) on conflict (user_id) do update set msgs_all = 1000`, [banned, hid, staff]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'x')`, [banned]);
  await h.q(`update profiles set leaderboard_hidden = true where id = $1`, [hid]);
  await h.q(`insert into leaderboard_exclusions (user_id, note) values ($1, 'staff test')`, [staff]);
  const many = [];
  for (let i = 0; i < 110; i++) many.push(await h.signup(`m${i}@679.dev`, `m${i}x679`));
  await h.q(`insert into leaderboard_stats (user_id, msgs_all) select x.id, 200 - x.i from unnest($1::uuid[]) with ordinality x(id, i)`, [many]);
  await h.q(`update leaderboard_stats set msgs_all = 199 where user_id = $1`, [many[1]]); // tie with many[0]
  await h.q(`select public.refresh_leaderboards()`);
  h.eq('board holds 100', (await h.one(`select count(*)::int n from leaderboard_board where board = 'messages_all'`)).n, 100);
  h.eq('banned / hidden / excluded / bots off the board',
    (await h.one(`select count(*)::int n from leaderboard_board where user_id = any($1)`, [[banned, hid, staff, bot]])).n, 0);
  h.eq('a second tick rewrites nothing', (await h.one(`select public.refresh_leaderboards() n`)).n, 0);

  await h.as(a);
  h.eq('flag off for a normal user: empty', (await h.one(`select public.leaderboard_page('messages_all') b`)).b.top.length, 0);
  await h.fails('unknown board refused', `select public.leaderboard_page('nope')`);
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid || $2::uuid where key = 'global_leaderboards'`, [a, hid]);
  await h.as(a);
  const p = (await h.one(`select public.leaderboard_page('messages_all') b`)).b;
  h.eq('top 50', p.top.length, 50);
  h.eq('ties share a rank', [p.top[0].pos, p.top[1].pos, p.top[2].pos, p.top[0].score], [1, 1, 3, 199]);
  // 110 + b (10) + banned / hidden / excluded (1000 each, still counted by the approximate count) above a's 7.
  h.eq('own rank outside the top 100 (approx)', p.me, { pos: 115, score: 8, approx: true, capped: false });
  h.eq('no score this week: no rank', (await h.one(`select public.leaderboard_page('voice_week') b`)).b.me, { pos: null, score: 0, approx: false, capped: false });
  await h.admin();
  await h.q(`update leaderboard_stats set msgs_all = 150 where user_id = $1`, [a]);
  await h.q(`select public.refresh_leaderboards()`);
  await h.as(a);
  const p2 = (await h.one(`select public.leaderboard_page('messages_all') b`)).b;
  h.eq('inside the top 100: exact', p2.me.approx, false);
  await h.as(hid);
  const ph = (await h.one(`select public.leaderboard_page('messages_all') b`)).b;
  h.eq('hidden: no rank, told so', [ph.me, ph.hidden], [null, true]);
  await h.admin();
  await h.q(`update profiles set leaderboard_hidden = true where id = $1`, [many[0]]);
  await h.as(a);
  h.eq('hiding drops off the top at once', (await h.one(`select public.leaderboard_page('messages_all') b`)).b.top.some((r) => r.id === many[0]), false);
  await h.fails('clients cannot read stats', `select * from leaderboard_stats`);
  await h.fails('clients cannot read the board', `select * from leaderboard_board`);
  await h.fails('clients cannot read voice sessions', `select * from leaderboard_voice_open`);
  await h.fails('clients cannot read exclusions', `select * from leaderboard_exclusions`);
  await h.fails('clients cannot tick', `select public.refresh_leaderboards()`);
  await h.fails('clients cannot bump', `select public.lb_bump(array[$1::uuid], array[current_date], array[1], array[0], array[0], array[1::bigint])`, [a]);
  await h.as(null);
  await h.fails('anon cannot read a board', `select public.leaderboard_page('messages_all')`);
  await h.admin();

  // Plans, with fresh stats and seq scans off as on a big table.
  await h.db.exec(`analyze messages; analyze leaderboard_stats; analyze leaderboard_board; set enable_seqscan = off`);
  const plan = async (sql, params = []) => (await h.q(`explain ${sql}`, params)).map((r) => Object.values(r)[0]).join('\n');
  h.eq('the message pass reads messages_created_idx', /messages_created_idx/.test(await plan(`select author_id, count(*) from messages where created_at >= now() - interval '12 minutes' and created_at < now() - interval '2 minutes' group by 1`)), true);
  h.eq('page reads the board by (board, ord)', /leaderboard_board_ord_idx|leaderboard_board_pkey/.test(await plan(`select user_id from leaderboard_board where board = 'messages_all' order by ord limit 50`)), true);
  h.eq('rank count uses the score index', /leaderboard_stats_msgs_week_idx/.test(await plan(`select count(*) from leaderboard_stats where week = current_date and msgs_week > 5`)), true);
  h.eq('all-time rank count uses its index', /leaderboard_stats_msgs_all_idx/.test(await plan(`select count(*) from leaderboard_stats where msgs_all > 5`)), true);
  h.eq('the backfill counts on messages_author_created_idx', /messages_author_created_idx/.test(await plan(`select count(*) from messages where author_id = $1 and created_at < now()`, [a])), true);
  await h.db.exec(`reset enable_seqscan`);
}
