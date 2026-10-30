// 667: Gifter badge + account level board (flag gift_badge_board). Base 24 + the flag functions (031/041), stand-ins
// for the live shapes 667 reads (plus_gifts / plus_events, profiles badges / shown_badge / account_level / avatar_deco,
// site_bans.expires_at, bots, bot_accounts, live column grants), then 667 twice (re-runnable).
// Checks: backfill counts paid gifts only (no giveaways), tiers at 1/10/25/50, a new gift awards, a refund takes it
// back and a won dispute gives it again (by payment intent and by checkout session), shown_badge follows the tier,
// users can't write gifts_given / badges but can flip leaderboard_hidden; the board skips banned, bots, hidden and
// level 0, ranks ties together, shows your own rank outside the top 50, hides you at once, needs the flag, and its
// cache and refresh aren't reachable from clients.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '667_gift_badge_level_board.sql'), 'utf8');

const STANDINS = String.raw`
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists avatar_deco text;
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
alter table public.profiles add column if not exists account_level smallint not null default 0;
alter table public.feature_flags add column if not exists servers uuid[] not null default '{}';
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.bots (id uuid primary key references public.profiles(id) on delete cascade);
create table if not exists public.bot_accounts (user_id uuid primary key references public.profiles(id) on delete cascade);
create table if not exists public.plus_events (id text primary key, user_id uuid, kind text, business_id text,
  created_at timestamptz not null default now(), state text not null default 'done', note text);
create table if not exists public.plus_gifts (
  id uuid primary key default gen_random_uuid(),
  gifter_id uuid references public.profiles(id) on delete set null,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  months int not null default 1, source text not null check (source in ('stripe', 'giveaway')),
  stripe_event text unique, created_at timestamptz not null default now());
alter table public.plus_gifts enable row level security;
revoke all on public.plus_gifts from anon, authenticated;
-- Live profiles has column grants only (085): no table-level update.
revoke update on public.profiles from authenticated;
grant update (username, shown_badge) on public.profiles to authenticated;
revoke select on public.profiles from anon, authenticated;
grant select (id, username, display_name, avatar_path, avatar_deco, badges, shown_badge, account_level) on public.profiles to anon, authenticated;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`667 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  const ANTIC = '00000000-0000-4000-8000-00000000a001';
  const g1 = await h.signup('g1@667.dev', 'g1');      // 1 paid gift + 1 giveaway
  const g10 = await h.signup('g10@667.dev', 'g10');   // 10 paid gifts
  const rcp = await h.signup('rcp@667.dev', 'rcp');
  const none = await h.signup('none@667.dev', 'none'); // only a giveaway
  await h.admin();
  await h.db.exec(STANDINS);
  await h.q(`insert into plus_gifts (gifter_id, recipient_id, source, stripe_event) values ($1, $2, 'stripe', 'evt_a'), ($1, $2, 'giveaway', null)`, [g1, rcp]);
  await h.q(`insert into plus_gifts (gifter_id, recipient_id, source, stripe_event) values ($1, $2, 'giveaway', null)`, [none, rcp]);
  await h.q(`insert into plus_gifts (gifter_id, recipient_id, source, stripe_event) select $1, $2, 'stripe', 'evt_b' || i from generate_series(1, 10) i`, [g10, rcp]);
  await h.q(`insert into plus_events (id, kind, business_id) values ('evt_b1', 'checkout.session.completed', 'cs_old')`);
  await h.q(`update profiles set badges = '{early}', shown_badge = 'gifter_1' where id = $1`, [g10]);

  await h.ok('667 runs', () => h.db.exec(MIG));
  await h.ok('667 re-runs cleanly', () => h.db.exec(MIG));
  const prof = (u) => h.one(`select gifts_given, badges, shown_badge from profiles where id = $1`, [u]);

  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'gift_badge_board'`);
  h.eq('flag test mode for HQ + Antic', [flag.mode, flag.servers, flag.users], ['test', ['00000000-0000-4000-8000-00000000b001'], [ANTIC]]);

  // ---------- gifter badge ----------
  h.eq('backfill: one paid gift (giveaway skipped)', await prof(g1), { gifts_given: 1, badges: ['gifter_1'], shown_badge: null });
  h.eq('backfill: 10 gifts is tier 2, other badges kept, shown badge follows', await prof(g10), { gifts_given: 10, badges: ['early', 'gifter_2'], shown_badge: 'gifter_2' });
  h.eq('backfill: giveaways alone give nothing', (await prof(none)).badges, []);
  await h.q(`insert into plus_gifts (gifter_id, recipient_id, source, stripe_event) select $1, $2, 'stripe', 'evt_c' || i from generate_series(1, 15) i`, [g10, rcp]);
  h.eq('a new paid gift moves the tier (25 = tier 3)', await prof(g10), { gifts_given: 25, badges: ['early', 'gifter_3'], shown_badge: 'gifter_3' });
  await h.q(`insert into plus_gifts (gifter_id, recipient_id, source, stripe_event) select $1, $2, 'stripe', 'evt_d' || i from generate_series(1, 25) i`, [g10, rcp]);
  h.eq('50 gifts is tier 4', (await prof(g10)).badges, ['early', 'gifter_4']);

  await h.q(`update plus_gifts set payment_intent = 'pi_a' where stripe_event = 'evt_a'`);
  await h.q(`set role service_role`);
  h.eq('refund by payment intent marks one gift', (await h.one(`select public.gift_mark_refunded('pi_a', null, true) n`)).n, 1);
  h.eq('a second refund event changes nothing', (await h.one(`select public.gift_mark_refunded('pi_a', null, true) n`)).n, 0);
  await h.admin();
  h.eq('refunded: badge and count gone', await prof(g1), { gifts_given: 0, badges: [], shown_badge: null });
  await h.q(`set role service_role`);
  h.eq('won dispute counts it again', (await h.one(`select public.gift_mark_refunded('pi_a', null, false) n`)).n, 1);
  h.eq('old gift found by checkout session', (await h.one(`select public.gift_mark_refunded('pi_old', 'cs_old', true) n`)).n, 1);
  await h.admin();
  h.eq('badge back after the won dispute', (await prof(g1)).badges, ['gifter_1']);
  h.eq('session match records the payment intent', (await h.one(`select payment_intent from plus_gifts where stripe_event = 'evt_b1'`)).payment_intent, 'pi_old');
  h.eq('49 left after the old refund: tier 3', await prof(g10), { gifts_given: 49, badges: ['early', 'gifter_3'], shown_badge: 'gifter_3' });

  await h.as(g1);
  await h.fails('users cannot call gift_mark_refunded', `select public.gift_mark_refunded('pi_a', null, true)`);
  await h.fails('users cannot call gifter_recount', `select public.gifter_recount($1)`, [g1]);
  await h.fails('users cannot write gifts_given', `update profiles set gifts_given = 99 where id = $1`, [g1]);
  await h.fails('users cannot write badges', `update profiles set badges = '{gifter_4}' where id = $1`, [g1]);
  await h.ok('users can flip leaderboard_hidden', () => h.q(`update profiles set leaderboard_hidden = true where id = $1`, [g1]));
  h.eq('and read their own', (await h.one(`select public.my_leaderboard_hidden() v`)).v, true);
  await h.fails('nobody can list who is hidden', `select id from profiles where leaderboard_hidden`);
  await h.q(`update profiles set leaderboard_hidden = false where id = $1`, [g1]);

  // ---------- level board ----------
  await h.admin();
  const ids = [];
  for (let i = 0; i < 55; i++) ids.push(await h.signup(`lv${i}@667.dev`, `lv${i}`));
  // lv0..lv54 at levels 60 down to 6; lv0 and lv1 tie at 60.
  await h.q(`update profiles p set account_level = case when x.i = 1 then 60 else 62 - x.i end
    from unnest($1::uuid[]) with ordinality x(id, i) where p.id = x.id`, [ids]);
  const banned = await h.signup('ban@667.dev', 'ban667');
  const bot = await h.signup('bot@667.dev', 'bot667');
  const botBadge = await h.signup('botb@667.dev', 'botb667');
  const hid = await h.signup('hid@667.dev', 'hid667');
  await h.q(`update profiles set account_level = 99 where id = any($1)`, [[banned, bot, botBadge, hid]]);
  await h.q(`update profiles set badges = '{bot}' where id = $1`, [botBadge]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'x')`, [banned]);
  await h.q(`insert into bots (id) values ($1)`, [bot]);
  await h.q(`update profiles set leaderboard_hidden = true where id = $1`, [hid]);
  await h.q(`update profiles set account_level = 3 where id = $1`, [g1]);
  await h.q(`select public.refresh_level_board()`);
  h.eq('board skips banned, bots, hidden and level 0', (await h.one(`select count(*)::int n from level_board`)).n, 56);
  h.eq('level counts: 55 levels with someone on them + level 3', (await h.one(`select count(*)::int n, sum(n)::int t from level_counts`)), { n: 55, t: 56 });
  h.eq('a second refresh rewrites nothing', (await h.one(`select public.refresh_level_board() n`)).n, 0);

  await h.as(g1);
  const page = (await h.one(`select public.level_board_page() b`)).b;
  h.eq('flag off for a normal user: empty board', page.top.length, 0);
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'gift_badge_board'`, [g1]);
  await h.as(g1);
  const b = (await h.one(`select public.level_board_page() b`)).b;
  h.eq('top 50 only', b.top.length, 50);
  h.eq('ties share a rank', [b.top[0].pos, b.top[1].pos, b.top[2].pos], [1, 1, 3]);
  h.eq('own rank outside the top 50', b.me, { pos: 56, level: 3 });
  await h.admin();
  await h.q(`update profiles set account_level = 59 where id = $1`, [g1]);
  await h.as(g1);
  h.eq('own rank follows your live level', (await h.one(`select public.level_board_page() b`)).b.me, { pos: 3, level: 59 });
  await h.q(`update profiles set leaderboard_hidden = true where id = $1`, [g1]);
  const b2 = (await h.one(`select public.level_board_page() b`)).b;
  h.eq('hiding yourself works at once', [b2.me, b2.hidden], [null, true]);
  await h.admin();
  await h.q(`update profiles set leaderboard_hidden = true where id = $1`, [ids[0]]);
  await h.as(g1);
  const b3 = (await h.one(`select public.level_board_page() b`)).b;
  h.eq('someone who hides drops off the top at once', b3.top.some((r) => r.id === ids[0]), false);
  await h.fails('clients cannot read the cache', `select * from level_board`);
  await h.fails('clients cannot read the counts', `select * from level_counts`);
  await h.fails('clients cannot refresh it', `select public.refresh_level_board()`);
  await h.as(null);
  await h.fails('anon cannot read the board', `select public.level_board_page()`);
  await h.admin();
}
