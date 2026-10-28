// 541: signup domain cap of 3 a day; a new domain with 3 confirmed accounts is blocked for good (everyone mode only);
// exact-match block check. feature_flags and mod_log are small stand-ins with the live columns these use.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const M322 = mig('322_signup_domain_cap.sql');
const MIG = mig('541_signup_domain_autoblock.sql');

const STANDINS = `
alter table auth.users add column if not exists created_at timestamptz not null default now();
alter table auth.users add column if not exists email_confirmed_at timestamptz;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
  target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(M322);
  // Before 541: an established company (first account 30 days ago, 2 confirmed) and a school that hit the cap.
  await h.q(`insert into auth.users (email, created_at, email_confirmed_at) values
    ('a@oldco.com', now() - interval '30 days', now()), ('b@oldco.com', now() - interval '2 days', now()),
    ('k@lund.se', now() - interval '3 days', now())`);
  await h.db.exec(MIG);
  await h.ok('541 re-runs cleanly', () => h.db.exec(MIG));

  const gate = async (email) => (await h.one(`select signup_domain_gate($1) g`, [email])).g;
  const blocked = async (d) => (await h.one(`select count(*)::int n from blocked_email_domains where domain = $1`, [d])).n;
  const seen = async (d) => await h.one(`select confirmed, first_seen < now() - interval '7 days' old from signup_domain_seen where domain = $1`, [d]);
  const blockLogs = async () => (await h.one(`select count(*)::int n from mod_log where action = 'signup_domain_block'`)).n;
  const signup = (email, confirmed = false) =>
    h.one(`insert into auth.users (email, email_confirmed_at) values ($1, ${confirmed ? 'now()' : 'null'}) returning id`, [email]);
  const confirm = (id) => h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [id]);

  h.eq('backfill: first account time and confirmed count', await seen('oldco.com'), { confirmed: 2, old: true });
  h.eq('school allowlisted', (await h.one(`select count(*)::int n from signup_domain_ok where domain = 'lund.se'`)).n, 1);

  // Gate, test mode: never refuses.
  for (let i = 0; i < 4; i++) await gate(`t${i}@trial.shop`);
  h.eq('test: 5th still let in', (await gate('t5@trial.shop')).ok, true);

  await h.q(`update feature_flags set mode = 'everyone' where key = 'signup_domain_cap'`);
  for (let i = 0; i < 3; i++) h.eq(`gate: account ${i + 1} fine`, (await gate(`f${i}@a.cap.shop`)).ok, true);
  const g = await gate('f3@cap.shop');
  h.eq('gate: 4th refused for today', [g.ok, g.capped], [false, true]);
  h.eq('gate alone never blocks for good', await blocked('cap.shop'), 0);
  for (const bad of ['x@%.%', 'x@%.com', 'x@a_b.com', 'x@a..com', 'x@-a.com', 'x@com']) {
    h.eq(`gate refuses odd domain ${bad}`, (await gate(bad)).ok, false);
  }
  h.eq('odd domains take no slot', (await h.one(`select count(*)::int n from signup_domain_hits where domain like '%\\%%' or domain like '%\\_%'`)).n, 0);

  // Auto-block: needs 3 confirmed on a new domain.
  const farm = [];
  for (let i = 0; i < 5; i++) farm.push((await signup(`u${i}@farm.shop`)).id);
  h.eq('unconfirmed sign-ups never block', await blocked('farm.shop'), 0);
  await confirm(farm[0]);
  await confirm(farm[1]);
  h.eq('2 confirmed: not yet', await blocked('farm.shop'), 0);
  await confirm(farm[2]);
  h.eq('3rd confirmed on a new domain: blocked', [await blocked('farm.shop'), await blockLogs()], [1, 1]);
  await confirm(farm[3]);
  h.eq('logged once', await blockLogs(), 1);
  h.eq('accounts already made stay', (await h.one(`select count(*)::int n from auth.users where email like '%@farm.shop'`)).n, 5);
  await h.fails('new sign-up on it refused', `insert into auth.users (email) values ('z@farm.shop')`);
  await h.fails('subdomain refused too', `insert into auth.users (email) values ('z@mx.farm.shop')`);
  const b = await gate('later@farm.shop');
  h.eq('gate says blocked', [b.ok, b.blocked], [false, true]);

  await signup('s0@sub.farm2.shop', true);
  await signup('s1@farm2.shop', true);
  await signup('s2@x.farm2.shop', true);
  h.eq('confirmed on sign-up counts, subdomains count as the domain', await blocked('farm2.shop'), 1);

  const oc = (await signup('c@oldco.com')).id;
  await confirm(oc);
  h.eq('established domain (first account 30 days ago) never blocked, not even written', [await blocked('oldco.com'), (await seen('oldco.com')).confirmed], [0, 2]);
  for (let i = 0; i < 4; i++) await signup(`g${i}@gmail.com`, true);
  for (let i = 0; i < 4; i++) await signup(`s${i}@lund.se`, true);
  h.eq('big providers and allowlisted schools never blocked', [await blocked('gmail.com'), await blocked('lund.se')], [0, 0]);
  for (let i = 0; i < 4; i++) await signup(`p${i}@kentwoodschools.org`, true);
  for (let i = 0; i < 4; i++) await signup(`w${i}@student.k12.wv.us`, true);
  h.eq('school-like names and state domains never blocked', [await blocked('kentwoodschools.org'), await blocked('wv.us')], [0, 0]);
  for (let i = 0; i < 3; i++) await gate(`k${i}@school.farm9.shop`);
  h.eq('a "school" subdomain on a farm is still capped', (await gate('k3@school.farm9.shop')).ok, false);
  for (let i = 0; i < 3; i++) await signup(`k${i}@student.farm9.shop`, true);
  h.eq('and still auto-blocked', await blocked('farm9.shop'), 1);
  for (let i = 0; i < 3; i++) await gate(`v${i}@myschool.shop`);
  h.eq('a school-named farm domain is capped', (await gate('v3@myschool.shop')).ok, false);
  for (let i = 0; i < 3; i++) await signup(`v${i}@myschool.shop`, true);
  h.eq('and auto-blocked (cheap ending)', await blocked('myschool.shop'), 1);
  h.eq('exempt domains not tracked per sign-up', (await h.one(`select count(*)::int n from signup_domain_seen where domain = 'gmail.com'`)).n, 0);

  await h.q(`update feature_flags set mode = 'test' where key = 'signup_domain_cap'`);
  for (let i = 0; i < 3; i++) await signup(`q${i}@quiet.shop`, true);
  h.eq('test mode: counts but never blocks', [await blocked('quiet.shop'), (await seen('quiet.shop')).confirmed], [0, 3]);

  // Exact match: a % row is no longer a wildcard.
  await h.q(`insert into blocked_email_domains (domain) values ('%.com')`);
  await h.ok('a % row blocks nothing else', () => h.q(`insert into auth.users (email) values ('ok@normal.com')`));
  await h.q(`delete from blocked_email_domains where domain = '%.com'`);
  await h.fails('the old list still works', `insert into auth.users (email) values ('z@cap.shop.farm.shop')`);

  await h.as(null);
  await h.fails('anon cannot call the gate', `select signup_domain_gate('a@b.c')`);
  await h.fails('anon cannot read the domain counts', `select * from signup_domain_seen`);
  await h.admin();
}
