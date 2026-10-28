// 539: EU checkout tables and the staff withdrawal functions. Stand-ins for what 537 runs next to (PGlite stops at 024).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '539_eu_checkout.sql'), 'utf8');

export default async function (h) {
  h.eq('539 has no drop / delete / truncate', /\b(drop|delete\s+from|truncate)\b/i.test(MIG), false);
  await h.admin();
  await h.db.exec(`
    create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
      mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
    create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
    create table if not exists public.site_admins (user_id uuid primary key);
    create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
  `);
  await h.db.exec(MIG);
  await h.db.exec(MIG); // re-runnable

  const boss = await h.signup('boss537@x.test', 'boss537');
  const buyer = await h.signup('buyer537@x.test', 'buyer537');
  await h.q(`insert into public.site_admins values ($1)`, [boss]);
  h.eq('flag in test', (await h.one(`select mode from public.feature_flags where key = 'eu_checkout'`)).mode, 'test');

  // The server (service role) writes these; clients can't touch them.
  await h.q(`insert into public.checkout_consents (user_id, kind, country, waiver_text, terms_version) values ($1, 'plus', 'DE', 'Start now.', '26 October 2026')`, [buyer]);
  const w1 = (await h.one(`insert into public.withdrawals (user_id, stripe_sub, label, paid_cents, refund_cents, currency, status, error) values ($1, 'sub_A', 'Yapin’ Plus', 499, 400, 'usd', 'refund_failed', 'no') returning id`, [buyer])).id;
  await h.q(`insert into public.withdrawals (user_id, stripe_sub, label, paid_cents, refund_cents, currency, status) values ($1, 'sub_B', 'Bots+', 299, 250, 'usd', 'refunded')`, [buyer]);
  await h.fails('one withdrawal per subscription', `insert into public.withdrawals (user_id, stripe_sub, status) values ($1, 'sub_A', 'refunded')`, [buyer]);
  await h.fails('bad status', `insert into public.withdrawals (user_id, stripe_sub, status) values ($1, 'sub_C', 'maybe')`, [buyer]);
  await h.q(`insert into public.cancel_requests (email, what, token_hash) values ('buyer537@x.test', 'plus', 'h1')`);
  await h.fails('bad cancel kind', `insert into public.cancel_requests (email, what, token_hash) values ('a@b.c', 'everything', 'h2')`);

  await h.as(buyer);
  await h.fails('buyer cannot read consents', `select * from public.checkout_consents`);
  await h.fails('buyer cannot read withdrawals', `select * from public.withdrawals`);
  await h.fails('buyer cannot read cancel requests', `select * from public.cancel_requests`);
  await h.fails('buyer cannot list withdrawals', `select * from public.staff_withdrawals(false)`);
  await h.fails('buyer cannot mark done', `select public.staff_withdrawal_done($1)`, [w1]);

  await h.as(boss);
  const open = await h.q(`select * from public.staff_withdrawals(true)`);
  h.eq('one to refund', open.length, 1);
  h.eq('with username', open[0].username, 'buyer537');
  h.eq('all lists both', (await h.q(`select * from public.staff_withdrawals(false)`)).length, 2);
  await h.q(`select public.staff_withdrawal_done($1, 're_123')`, [w1]);
  await h.fails('only once', `select public.staff_withdrawal_done($1)`, [w1]);
  h.eq('none left', (await h.q(`select * from public.staff_withdrawals(true)`)).length, 0);

  await h.admin();
  const w = await h.one(`select status, note, handled_by from public.withdrawals where id = $1`, [w1]);
  h.eq('marked done', w.status, 'manual_done');
  h.eq('note kept', w.note, 're_123');
  h.eq('who', w.handled_by, boss);
  h.eq('logged', (await h.q(`select 1 from public.mod_log where action = 'withdrawal_refunded'`)).length, 1);
}
