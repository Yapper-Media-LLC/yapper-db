// 493: Stripe fulfilment that can't be lost or doubled (security pass 2, B1-B3). Base 24 + flags, with stand-ins for
// the live billing tables (plus_events, server_plus, bot_hosting, supercharges as of Oct 25) and the two renew
// functions 493 wraps, then 493 twice (re-runnable).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.profiles add column if not exists plus_until timestamptz;
create table if not exists public.plus_events (id text primary key, user_id uuid, kind text, created_at timestamptz not null default now(),
  amount integer, currency text, ref text, email text, note text);
create table if not exists public.server_plus (server_id uuid primary key references public.servers (id) on delete cascade, until timestamptz,
  stripe_customer text, granted_by uuid, updated_at timestamptz not null default now());
create table if not exists public.bot_hosting (bot_id uuid primary key default gen_random_uuid(), until timestamptz, stripe_sub text);
create table if not exists public.supercharges (id uuid primary key default gen_random_uuid(), until timestamptz, stripe_sub text unique);
create or replace function public.bot_hosting_renew(p_sub text, p_days int default 31) returns timestamptz language sql as $$
  update public.bot_hosting set until = greatest(now(), coalesce(until, now())) + make_interval(days => p_days) where stripe_sub = p_sub and p_sub is not null returning until
$$;
create or replace function public.renew_supercharge(p_sub text, p_days int) returns uuid language sql as $$
  update public.supercharges set until = greatest(now(), coalesce(until, now())) + make_interval(days => p_days) where stripe_sub = p_sub and p_sub is not null returning id
$$;
insert into public.plus_events (id, kind) values ('evt_old', 'invoice.paid');
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '493_billing_durable.sql'), 'utf8');
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`493 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('493 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('old events count as done', (await h.one(`select state from plus_events where id = 'evt_old'`)).state, 'done');

  const amy = await h.signup('amy493@test.dev', 'amy493');
  const bob = await h.signup('bob493@test.dev', 'bob493');
  await h.admin();
  const claim = async (id, bid, kind = 'checkout.session.completed') => (await h.one(`select billing_event_claim($1, $2, $3) r`, [id, kind, bid])).r;
  const finish = (id, ok) => h.q(`select billing_event_finish($1, $2, null)`, [id, ok]);

  // ---- The inbox ----
  h.eq('new event: go', await claim('evt_1', 'cs_1'), 'go');
  h.eq('same event while it runs: busy', await claim('evt_1', 'cs_1'), 'busy');
  await finish('evt_1', false);
  h.eq('after a failure the retry handles it (the old code called this a duplicate)', await claim('evt_1', 'cs_1'), 'go');
  h.eq('attempts counted', (await h.one(`select attempts from plus_events where id = 'evt_1'`)).attempts, 2);
  await h.q(`update plus_events set claimed_at = now() - interval '3 minutes' where id = 'evt_1'`);
  h.eq('a delivery that died mid-way is taken over after 2 minutes', await claim('evt_1', 'cs_1'), 'go');
  await finish('evt_1', true);
  h.eq('done: dup', await claim('evt_1', 'cs_1'), 'dup');
  // completed (unpaid, answered "pending") then async_payment_succeeded for the same session: the second must run.
  h.eq('another event for the same session still runs (delayed payments)', await claim('evt_1b', 'cs_1', 'checkout.session.async_payment_succeeded'), 'go');
  h.eq('no business id still works', await claim('evt_2', null, 'customer.updated'), 'go');

  // ---- Plus, atomic and once per payment ----
  const plus = async (bid, ev = 'evt') => (await h.one(`select extend_plus($1, 31, $2, $3) u`, [amy, bid, ev])).u;
  const u1 = new Date(await plus('in_1'));
  const days = (d) => Math.round((d.getTime() - Date.now()) / 86_400_000);
  h.eq('first payment: 31 days', days(u1), 31);
  const u2 = new Date(await plus('in_2'));
  h.eq('second payment adds on top (no lost month)', days(u2), 62);
  const u3 = new Date(await plus('in_2'));
  h.eq('the same payment again changes nothing', u3.getTime(), u2.getTime());
  await h.fails('unknown user', `select extend_plus('00000000-0000-0000-0000-000000000000'::uuid, 31, 'in_x', 'e')`);
  h.eq('a failed extension leaves no fulfilment row behind', (await h.one(`select count(*)::int n from billing_fulfilments where business_id = 'in_x'`)).n, 0);
  await h.fails('no business id', `select extend_plus($1, 31, '', 'e')`, [amy]);
  await h.q(`update profiles set plus_until = now() - interval '10 days' where id = $1`, [amy]);
  h.eq('expired Plus starts from now', days(new Date(await plus('in_3'))), 31);

  // ---- Server Plus ----
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  const sp = async (bid, payer = null, sub = 'sub_A') =>
    (await h.one(`select extend_server_plus($1, 31, $2, 'e', 'cus_A', $3, $4) u`, [sid, bid, sub, payer])).u;
  h.eq('server plus: 31 days', days(new Date(await sp('cs_s1', bob))), 31);
  h.eq('renewal adds on top', days(new Date(await sp('in_s2'))), 62);
  h.eq('same invoice again: nothing', days(new Date(await sp('in_s2'))), 62);
  h.eq('payer and subscription kept (renewal without payer keeps it)',
    await h.one(`select payer_id, stripe_sub, stripe_customer from server_plus where server_id = $1`, [sid]), { payer_id: bob, stripe_sub: 'sub_A', stripe_customer: 'cus_A' });
  await h.fails('unknown server', `select extend_server_plus(gen_random_uuid(), 31, 'cs_z', 'e', null, null, null)`);

  // ---- Renewals once per invoice ----
  await h.db.exec(`insert into bot_hosting (stripe_sub) values ('sub_H'); insert into supercharges (stripe_sub) values ('sub_C')`);
  const bh = async (bid) => new Date((await h.one(`select bot_hosting_renew_once('sub_H', 31, $1, 'e') u`, [bid])).u);
  h.eq('hosting renewal', days(await bh('in_h1')), 31);
  h.eq('hosting renewal replayed: same', days(await bh('in_h1')), 31);
  h.eq('next invoice adds on', days(await bh('in_h2')), 62);
  await h.q(`select renew_supercharge_once('sub_C', 31, 'in_c1', 'e')`);
  await h.q(`select renew_supercharge_once('sub_C', 31, 'in_c1', 'e')`);
  h.eq('supercharge renewal once', days(new Date((await h.one(`select until from supercharges where stripe_sub = 'sub_C'`)).until)), 31);

  // ---- Cancellations kept until confirmed ----
  await h.q(`select stripe_cancel_later('sub_X1', 'plan switch'), stripe_cancel_later('sub_X2', 'deleted bot')`);
  await h.fails('only Stripe subscription ids', `select stripe_cancel_later('nope', 'x')`);
  const due = (await h.q(`select stripe_cancel_due(10) s`)).map((r) => r.s).sort();
  h.eq('both due', due, ['sub_X1', 'sub_X2']);
  h.eq('claimed: not due again right away', (await h.q(`select stripe_cancel_due(10) s`)).length, 0);
  await h.q(`select stripe_cancel_result('sub_X1', true, null), stripe_cancel_result('sub_X2', false, 'down')`);
  const jobs = await h.q(`select sub, done_at is not null done, last_error, next_at > now() later from stripe_cancel_jobs order by sub`);
  h.eq('done one stays done, failed one backs off', jobs.map((j) => [j.sub, j.done, j.last_error, j.later]), [['sub_X1', true, null, true], ['sub_X2', false, 'down', true]]);
  await h.q(`update stripe_cancel_jobs set next_at = now() - interval '1 second', attempts = 30 where sub = 'sub_X2'`);
  h.eq('gives up after 30 tries (left for staff)', (await h.q(`select stripe_cancel_due(10) s`)).length, 0);
  await h.q(`select stripe_cancel_later('sub_X1', 'again')`);
  h.eq('a finished job queued again is due again', (await h.q(`select stripe_cancel_due(10) s`)).map((r) => r.s), ['sub_X1']);

  // ---- Nobody else can touch any of it ----
  await h.as(amy);
  for (const t of ['billing_fulfilments', 'stripe_cancel_jobs']) await h.fails(`users can't read ${t}`, `select * from ${t}`);
  await h.fails('users can\'t extend Plus', `select extend_plus($1, 31, 'in_hack', 'e')`, [amy]);
  await h.fails('users can\'t claim events', `select billing_event_claim('evt_h', 'x', null)`);
  await h.fails('users can\'t queue cancels', `select stripe_cancel_later('sub_Z', 'x')`);
  await h.as(null);
  await h.fails('anon can\'t extend server plus', `select extend_server_plus($1, 31, 'b', 'e', null, null, null)`, [sid]);
  await h.admin();
  h.eq('billing_trust flag in test', (await h.one(`select mode from feature_flags where key = 'billing_trust'`)).mode, 'test');
}
