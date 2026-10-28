// 611: Plus tenure (profiles.plus_since). The trigger starts a streak when Plus starts, keeps it through renewals
// and gaps of up to 7 days, restarts it after a longer gap; the backfill takes the first Plus payment or gift.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '611_plus_tenure.sql'), 'utf8');

// Live shapes (Oct 27): just the columns 611 reads.
const STANDINS = String.raw`
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.feature_flags add column if not exists servers uuid[] not null default '{}';
create table if not exists public.plus_events (id text primary key, user_id uuid, kind text, created_at timestamptz not null default now(),
  state text not null default 'done', note text);
-- Live profiles has column grants only (085): no table-level update.
revoke update on public.profiles from authenticated;
grant update (username, bio) on public.profiles to authenticated;
create table if not exists public.plus_gifts (id bigserial primary key, recipient_id uuid, created_at timestamptz not null default now());
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`611 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  const paid = await h.signup('paid611@test.dev', 'paid611');
  const gifted = await h.signup('gift611@test.dev', 'gift611');
  const granted = await h.signup('grant611@test.dev', 'grant611');
  const lapsed = await h.signup('lapsed611@test.dev', 'lapsed611');
  const fresh = await h.signup('fresh611@test.dev', 'fresh611');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.q(`update profiles set plus_until = now() + interval '20 days' where id = any($1)`, [[paid, gifted, granted]]);
  await h.q(`update profiles set plus_until = now() - interval '30 days' where id = $1`, [lapsed]);
  await h.q(`insert into plus_events (id, user_id, kind, created_at) values
    ('e1', $1, 'checkout.session.completed', now() - interval '14 days'), ('e2', $1, 'invoice.paid', now() - interval '2 days'),
    ('e3', $1, 'checkout.session.completed', now() - interval '20 days')`, [paid]);
  await h.q(`update plus_events set note = 'underpaid plus' where id = 'e3'`);
  await h.q(`insert into plus_gifts (recipient_id, created_at) values ($1, now() - interval '9 days')`, [gifted]);
  await h.q(`insert into plus_events (id, user_id, kind, created_at) values ('e4', $1, 'checkout.session.completed', now() - interval '40 days')`, [lapsed]);

  await h.ok('611 runs', () => h.db.exec(MIG));
  await h.ok('611 re-runs cleanly', () => h.db.exec(MIG));
  const days = async (u) => (await h.one(`select round(extract(epoch from now() - plus_since) / 86400)::int d from profiles where id = $1`, [u])).d;
  h.eq('backfill: first good payment (the underpaid one is skipped)', await days(paid), 14);
  h.eq('backfill: a gift counts', await days(gifted), 9);
  h.eq('backfill: Plus with no payment or gift starts now', await days(granted), 0);
  h.eq('backfill: lapsed Plus gets nothing', (await h.one(`select plus_since from profiles where id = $1`, [lapsed])).plus_since, null);
  h.eq('flag row is in test mode', (await h.one(`select mode from feature_flags where key = 'plus_tenure_badges'`)).mode, 'test');

  await h.q(`update profiles set plus_until = plus_until + interval '31 days' where id = $1`, [paid]);
  h.eq('a renewal keeps the streak', await days(paid), 14);
  await h.q(`update profiles set plus_until = now() + interval '31 days' where id = $1`, [fresh]);
  h.eq('first Plus starts a streak', await days(fresh), 0);
  await h.q(`update profiles set plus_since = now() - interval '60 days', plus_until = now() - interval '3 days' where id = $1`, [gifted]);
  await h.q(`update profiles set plus_until = now() + interval '31 days' where id = $1`, [gifted]);
  h.eq('back within 7 days: streak kept', await days(gifted), 60);
  await h.q(`update profiles set plus_until = now() + interval '31 days' where id = $1`, [lapsed]);
  h.eq('back after a month off: streak restarts', await days(lapsed), 0);
  await h.q(`update profiles set plus_since = now() - interval '90 days', plus_until = now() - interval '1 day' where id = $1`, [granted]);
  h.eq('Plus taken away: streak kept for now', await days(granted), 90);
  await h.q(`update profiles set username = 'renamed611' where id = $1`, [paid]);
  h.eq('other profile edits leave it alone', await days(paid), 14);

  await h.as(fresh);
  h.eq('everyone can read plus_since', (await h.one(`select plus_since is not null v from profiles where id = $1`, [paid])).v, true);
  await h.fails('nobody can set their own plus_since', `update profiles set plus_since = now() - interval '5 years' where id = $1`, [fresh]);
  await h.as(null);
}
