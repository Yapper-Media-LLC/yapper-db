// 322: at most 5 new accounts a day per email domain (big providers and schools exempt); test mode only logs.
// feature_flags and mod_log are small stand-ins with the live columns the gate uses.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '322_signup_domain_cap.sql'), 'utf8');

const STANDINS = `
alter table auth.users add column if not exists created_at timestamptz not null default now();
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
  target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  // Four from a farm domain (one on a subdomain) and one from gmail in the last day, one from the farm two days ago (outside the window).
  for (let i = 0; i < 4; i++) await h.q(`insert into auth.users (email) values ($1)`, [i ? `f${i}@farm.shop` : 'f0@a.farm.shop']);
  await h.q(`insert into auth.users (email, created_at) values ('old@farm.shop', now() - interval '2 days')`);
  await h.q(`insert into auth.users (email) values ('a@gmail.com')`);
  await h.db.exec(MIG);
  await h.ok('322 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('seeded from the last day only, once', (await h.one(`select count(*)::int n from signup_domain_hits where domain = 'farm.shop'`)).n, 4);
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'signup_domain_cap'`)).mode, 'test');

  const gate = async (email) => (await h.one(`select signup_domain_gate($1) g`, [email])).g;
  const hits = async (d) => (await h.one(`select count(*)::int n from signup_domain_hits where domain = $1`, [d])).n;
  const logs = async () => (await h.one(`select count(*)::int n from mod_log where action = 'signup_domain_cap'`)).n;

  // Test mode: holds slots and logs, never refuses.
  let g = await gate('x@farm.shop');
  h.eq('under the cap holds a slot', [g.ok, typeof g.hit], [true, 'number']);
  await h.q(`select signup_domain_release($1)`, [g.hit]);
  h.eq('released slot is gone', await hits('farm.shop'), 4);
  await gate('f4@mail.farm.shop');
  h.eq('a subdomain counts as its domain', await hits('farm.shop'), 5);
  g = await gate('x@farm.shop');
  h.eq('test mode: over the cap still lets them in', [g.ok, g.capped], [true, true]);
  h.eq('logged once', await logs(), 1);
  await gate('y@farm.shop');
  h.eq('not logged again the same day', await logs(), 1);

  await h.q(`update feature_flags set mode = 'everyone' where key = 'signup_domain_cap'`);
  const before = await hits('farm.shop');
  g = await gate('z@FARM.shop');
  h.eq('everyone: refused, no slot taken', [g.ok, await hits('farm.shop')], [false, before]);
  h.eq('everyone: subdomain refused too', (await gate('z@x.y.farm.shop')).ok, false);
  for (let i = 0; i < 6; i++) await gate(`g${i}@gmail.com`);
  h.eq('big providers never capped', (await gate('new@gmail.com')).ok, true);
  h.eq('big providers not counted', await hits('gmail.com'), 0);
  h.eq('outlook country domains exempt', [(await gate('a@outlook.fr')).ok, (await gate('a@hotmail.co.uk')).ok], [true, true]);
  for (let i = 0; i < 6; i++) {
    await gate(`s${i}@cs.mit.edu`);
    await gate(`k${i}@ox.ac.uk`);
    await gate(`f${i}@edu.farm2.shop`);
    await gate(`o${i}@outlook.farm3.shop`);
  }
  h.eq('school suffixes exempt', [(await gate('s@cs.mit.edu')).ok, (await gate('k@ox.ac.uk')).ok], [true, true]);
  h.eq('look-alike school/provider names are capped', [(await gate('f@edu.farm2.shop')).ok, (await gate('o@outlook.farm3.shop')).ok], [false, false]);
  h.eq('co.uk-style domains count three labels', (await h.one(`select signup_domain_base('mail.shop.co.uk') b`)).b, 'shop.co.uk');
  await h.q(`insert into signup_domain_ok (domain, note) values ('farm.shop', 'real company')`);
  h.eq('allowlisted by staff: fine again', (await gate('z@sub.farm.shop')).ok, true);
  await h.q(`update feature_flags set mode = 'off' where key = 'signup_domain_cap'`);
  h.eq('off: nothing', await gate('z@other.shop'), { ok: true });

  await h.as(null);
  await h.fails('anon cannot call it', `select signup_domain_gate('a@b.c')`);
  await h.fails('anon cannot read the counts', `select * from signup_domain_hits`);
  await h.fails('anon cannot release', `select signup_domain_release(1)`);
  await h.admin();
}
