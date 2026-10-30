// 632: placements (Boosts, Promoted spots) as monthly subscriptions. Base 24 + flags, the stage441 stand-ins (bots,
// staff, mod_log), 441/443/444 for bot_promotions, and stand-ins for the live server promotion functions (085/088/109
// were applied by hand and aren't in the repo in full) plus billing_fulfilments / stripe_cancel_later from 493.
// Checks: booking remembers the subscription and is idempotent per subscription, renewals add a month once per
// invoice, the end handler caps ends_at, staff ending a renewing row queues a Stripe cancellation, and nobody but
// service_role can call the new functions.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage441.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const SERVER_STANDINS = `
create table if not exists public.server_promotions (
  id uuid primary key default gen_random_uuid(), server_id uuid not null, starts_at timestamptz not null default now(), ends_at timestamptz not null,
  source text not null default 'stripe', stripe_event text unique, created_by uuid, views int default 0, clicks int default 0, joins int default 0,
  created_at timestamptz default now(), kind text not null default 'promote', mult int not null default 4);
create or replace function public.promo_slots() returns integer language sql immutable as $$ select 4 $$;
create or replace function public.boost_tiers() returns int[] language sql immutable as $$ select array[2, 4, 8] $$;
create or replace function public.next_promo_start(sid uuid) returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare t timestamptz; busy int; nxt timestamptz;
begin
  select greatest(now(), coalesce(max(ends_at), now())) into t from public.server_promotions where server_id = sid and kind = 'promote';
  loop
    select count(*), min(ends_at) into busy, nxt from public.server_promotions where kind = 'promote' and server_id <> sid and starts_at <= t and ends_at > t;
    exit when busy < public.promo_slots();
    t := nxt;
  end loop;
  return t;
end $$;
create or replace function public.book_promotion(sid uuid, p_kind text, p_source text, p_event text, p_by uuid, p_days integer, p_mult integer)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_start timestamptz;
begin
  if p_kind = 'promote' then v_start := public.next_promo_start(sid);
  else
    if p_mult is null or not (p_mult = any(public.boost_tiers())) then raise exception 'Unknown boost tier'; end if;
    select greatest(now(), coalesce(max(ends_at), now())) into v_start from public.server_promotions where server_id = sid and kind = 'boost' and mult = p_mult and ends_at > now();
  end if;
  insert into public.server_promotions (server_id, starts_at, ends_at, source, stripe_event, created_by, kind, mult)
  values (sid, v_start, v_start + make_interval(days => p_days), p_source, p_event, p_by, p_kind, coalesce(p_mult, 4));
  return v_start;
end $$;
create table if not exists public.billing_fulfilments (business_id text primary key, kind text not null, target uuid, event_id text, at timestamptz default now());
create table if not exists public.stripe_cancel_jobs (sub text primary key, reason text not null default '', attempts int default 0, last_error text,
  next_at timestamptz not null default now(), created_at timestamptz default now(), done_at timestamptz);
create or replace function public.stripe_cancel_later(p_sub text, p_reason text) returns void language sql security definer set search_path = public as $$
  insert into public.stripe_cancel_jobs (sub, reason) values (p_sub, left(coalesce(p_reason, ''), 200)) on conflict (sub) do nothing; $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(SERVER_STANDINS);
  await h.db.exec(mig('441_bot_promoted.sql'));
  await h.db.exec(mig('443_bot_promo_two_spots.sql'));
  await h.db.exec(mig('444_bot_boosts.sql'));
  const MIG = mig('632_promo_subscriptions.sql');
  await h.ok('632 runs', () => h.db.exec(MIG));
  await h.ok('632 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'promo_subs'`)).mode, 'test');

  const a = await h.signup('a@test.dev', 'alice'); // buyer, bot owner
  const z = await h.signup('z@test.dev', 'admin');
  const m = await h.signup('m@test.dev', 'mod');
  const bot = await h.signup('bot@test.dev', 'bot');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [z]);
  await h.q(`insert into site_moderators values ($1)`, [m]);
  await h.q(`insert into bots (id, owner_id, name, public, verified_at) values ($1, $2, 'Botty', true, now())`, [bot, a]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [a])).id;

  // Nobody but service_role books, renews or ends.
  for (const who of [a, z, m, null]) {
    await h.as(who);
    await h.fails('book_promotion_sub is service_role only', `select book_promotion_sub($1, 'boost', 8, 'sub_A', 'evt_1', $2, 31)`, [sid, a]);
    await h.fails('book_bot_placement_sub is service_role only', `select book_bot_placement_sub($1, 'promote', null, 'sub_B', 'evt_2', $2, 31)`, [bot, a]);
    await h.fails('renew_placement_once is service_role only', `select renew_placement_once('sub_A', 31, 'in_1', 'evt_3')`);
    await h.fails('end_placement_sub is service_role only', `select end_placement_sub('sub_A', null)`);
    await h.fails('placement_for_sub is service_role only', `select placement_for_sub('sub_A')`);
  }

  await h.admin();
  await h.db.exec(`set role service_role`);
  await h.fails('needs a real subscription id', `select book_promotion_sub($1, 'boost', 8, 'nope', 'evt_0', $2, 31)`, [sid, a]);
  // Server boost as a subscription.
  await h.q(`select book_promotion_sub($1, 'boost', 8, 'sub_A', 'evt_1', $2, 31)`, [sid, a]);
  const row = await h.one(`select stripe_sub, created_by, kind, mult, ends_at - now() > interval '30 days' long from server_promotions where server_id = $1`, [sid]);
  h.eq('row remembers the subscription and buyer', [row.stripe_sub, row.created_by, row.kind, row.mult, row.long], ['sub_A', a, 'boost', 8, true]);
  await h.q(`select book_promotion_sub($1, 'boost', 8, 'sub_A', 'evt_1b', $2, 31)`, [sid, a]);
  h.eq('same subscription again books nothing new', (await h.one(`select count(*)::int n from server_promotions where server_id = $1`, [sid])).n, 1);
  h.eq('placement_for_sub finds the server row', (await h.one(`select placement_for_sub('sub_A') j`)).j.table, 'server');
  h.eq('unknown subscription is null', (await h.one(`select placement_for_sub('sub_zzz') j`)).j, null);

  // Renewal: a month more, once per invoice.
  const before = (await h.one(`select ends_at from server_promotions where stripe_sub = 'sub_A'`)).ends_at;
  await h.q(`select renew_placement_once('sub_A', 31, 'in_1', 'evt_3')`);
  const after1 = (await h.one(`select ends_at from server_promotions where stripe_sub = 'sub_A'`)).ends_at;
  h.eq('renewal adds 31 days', Math.round((after1 - before) / 86_400_000), 31);
  await h.q(`select renew_placement_once('sub_A', 31, 'in_1', 'evt_3_retry')`);
  const after2 = (await h.one(`select ends_at from server_promotions where stripe_sub = 'sub_A'`)).ends_at;
  h.eq('same invoice again adds nothing', after2.getTime(), after1.getTime());
  await h.fails('renewing an unknown subscription fails', `select renew_placement_once('sub_zzz', 31, 'in_9', 'evt_9')`);

  // Ended by Stripe: capped at the paid period's end, never later.
  const n = (await h.one(`select end_placement_sub('sub_A', now() + interval '3 days') n`)).n;
  const ended = await h.one(`select ends_at - now() between interval '2 days 23 hours' and interval '3 days 1 hour' ok from server_promotions where stripe_sub = 'sub_A'`);
  h.eq('end caps ends_at at the period end', [n, ended.ok], [1, true]);
  h.eq('ending again touches nothing', (await h.one(`select end_placement_sub('sub_A', now() + interval '30 days') n`)).n, 0);

  // Bot Promoted spot as a subscription.
  await h.q(`select book_bot_placement_sub($1, 'promote', null, 'sub_B', 'evt_2', $2, 31)`, [bot, a]);
  await h.q(`select book_bot_placement_sub($1, 'promote', null, 'sub_B', 'evt_2b', $2, 31)`, [bot, a]);
  h.eq('one bot row per subscription', (await h.one(`select count(*)::int n from bot_promotions where bot_id = $1`, [bot])).n, 1);
  h.eq('placement_for_sub finds the bot row', (await h.one(`select placement_for_sub('sub_B') j`)).j.table, 'bot');
  await h.q(`select renew_placement_once('sub_B', 31, 'in_2', 'evt_4')`);
  h.eq('bot renewal lands', (await h.one(`select ends_at - now() > interval '60 days' ok from bot_promotions where stripe_sub = 'sub_B'`)).ok, true);
  await h.q(`select book_bot_placement_sub($1, 'boost', 4, 'sub_C', 'evt_5', $2, 31)`, [bot, a]);
  h.eq('bot boost subscription keeps its tier', (await h.one(`select mult from bot_promotions where stripe_sub = 'sub_C'`)).mult, 4);
  await h.db.exec(`reset role`);

  // Staff ending a renewing placement queues the Stripe cancellation.
  const pid = (await h.one(`select id from bot_promotions where stripe_sub = 'sub_B'`)).id;
  await h.as(m);
  await h.q(`select staff_end_bot_promotion($1, 'spam')`, [pid]);
  await h.admin();
  h.eq('bot cancellation queued', (await h.one(`select count(*)::int n from stripe_cancel_jobs where sub = 'sub_B'`)).n, 1);
  await h.db.exec(`set role service_role`);
  await h.q(`select renew_placement_once('sub_B', 31, 'in_3', 'evt_6')`);
  h.eq('a payment after staff ended it brings nothing back', (await h.one(`select ends_at <= now() ok from bot_promotions where stripe_sub = 'sub_B'`)).ok, true);
  await h.fails('a second row for the same subscription is refused', `insert into bot_promotions (bot_id, ends_at, stripe_sub) values ($1, now() + interval '1 day', 'sub_C')`, [bot]);
  await h.db.exec(`reset role`);
  await h.admin();
  const spid = (await h.one(`select id from server_promotions where stripe_sub = 'sub_A'`)).id;
  await h.as(z);
  await h.q(`select admin_end_promotion($1)`, [spid]);
  await h.admin();
  h.eq('server cancellation queued', (await h.one(`select count(*)::int n from stripe_cancel_jobs where sub = 'sub_A'`)).n, 1);
  h.eq('no job for one-off rows', (await h.one(`select count(*)::int n from stripe_cancel_jobs`)).n, 2);

  // The bot's owner sees which rows renew (column grant), others don't see the rows at all.
  await h.as(a);
  h.eq('owner reads stripe_sub', (await h.one(`select stripe_sub from bot_promotions where stripe_sub = 'sub_C'`)).stripe_sub, 'sub_C');
  await h.as(z);
  h.eq('staff read it too', (await h.q(`select stripe_sub from bot_promotions where stripe_sub = 'sub_C'`)).length, 1);
  await h.admin();
  await h.q(`delete from bot_promotions where stripe_sub = 'sub_C'`);
  h.eq('deleting a renewing row queues its cancellation', (await h.one(`select count(*)::int n from stripe_cancel_jobs where sub = 'sub_C'`)).n, 1);
}
