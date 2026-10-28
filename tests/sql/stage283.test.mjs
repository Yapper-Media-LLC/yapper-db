// 283: "Download your data" limit (data_export_hit), its table locked down, the flag, the three separate indexes, and the body running in one transaction.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const FILE = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '283_data_export.sql'), 'utf8');
// The CONCURRENTLY indexes sit in a comment block at the end, to be run one at a time outside a transaction.
const INDEXES = [...FILE.matchAll(/^-- (create index concurrently[^;]*;)/gm)].map((m) => m[1]);

export default async function (h) {
  await h.admin();
  await h.db.exec(`
    create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
      mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
    create table if not exists public.poll_ballots (poll_id uuid not null, user_id uuid not null, option_ids uuid[] not null default '{}',
      created_at timestamptz not null default now(), primary key (poll_id, user_id));
    create table if not exists public.server_first_joins (server_id uuid not null, user_id uuid not null, first_joined_at timestamptz not null default now(),
      primary key (server_id, user_id));`);
  // The body goes through apply_migration in one transaction, so it must not contain anything CONCURRENTLY.
  const run = async () => { await h.db.exec(`begin;\n${FILE}\ncommit;`); };
  await run();
  await h.ok('283 re-runs cleanly in one transaction', run);
  h.eq('no live concurrently in the body', /^\s*create index concurrently/im.test(FILE), false);
  h.eq('three indexes to run separately', INDEXES.length, 3);
  for (const i of INDEXES) { await h.db.exec(i); await h.db.exec(i); }
  h.eq('flag made in test mode', (await h.one(`select mode from feature_flags where key = 'data_export'`)).mode, 'test');
  h.eq('indexes exist', (await h.q(`select indexname from pg_indexes where indexname in ('reactions_user_idx', 'poll_ballots_user_idx', 'server_first_joins_user_idx') order by 1`)).map((r) => r.indexname),
    ['poll_ballots_user_idx', 'reactions_user_idx', 'server_first_joins_user_idx']);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');

  // Users can't touch the counter or call the function.
  await h.as(amy);
  await h.fails('users can’t read the table', `select * from data_exports`);
  await h.fails('users can’t write the table', `insert into data_exports (user_id) values ($1)`, [amy]);
  await h.fails('users can’t call the limit', `select data_export_hit($1)`, [amy]);
  await h.as(null);
  await h.fails('anon can’t call the limit', `select data_export_hit($1)`, [amy]);

  // The server: 3 a day per user, the 4th refused and not counted, others unaffected.
  await h.admin();
  await h.db.exec(`set role service_role`);
  const hit = async (u) => (await h.one(`select data_export_hit($1) as ok`, [u])).ok;
  h.eq('1st ok', await hit(amy), true);
  h.eq('2nd ok', await hit(amy), true);
  h.eq('3rd ok', await hit(amy), true);
  h.eq('4th refused', await hit(amy), false);
  h.eq('null user refused', await hit(null), false);
  h.eq('bob has his own 3', await hit(bob), true);
  await h.admin();
  h.eq('refused one not counted', (await h.one(`select count(*)::int n from data_exports where user_id = $1`, [amy])).n, 3);
  await h.q(`update data_exports set at = now() - interval '25 hours' where user_id = $1`, [amy]);
  await h.db.exec(`set role service_role`);
  h.eq('a day later it works again', await hit(amy), true);
  await h.admin();
}
