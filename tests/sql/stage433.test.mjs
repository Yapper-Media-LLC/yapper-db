// 433: a username held by a never-confirmed sign-up (over an hour old) is free for a new sign-up.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '433_username_unconfirmed.sql'), 'utf8');

const STANDINS = `
alter table auth.users add column if not exists email_confirmed_at timestamptz;
alter table auth.users add column if not exists last_sign_in_at timestamptz;
alter table auth.users add column if not exists created_at timestamptz not null default now();
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (user_id uuid primary key);
create table if not exists public.username_holds (name_key text primary key, user_id uuid, until timestamptz);
create table if not exists public.feature_flags (key text primary key, mode text);
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('433 re-runs cleanly', () => h.db.exec(MIG));
  const taken = async (n) => (await h.one(`select srv_username_taken($1) v`, [n])).v;
  const nameOf = async (id) => (await h.one(`select username from profiles where id = $1`, [id])).username;

  const stale = await h.signup('typo@test.dev', 'luna');
  const fresh = await h.signup('wait@test.dev', 'mars');
  const real = await h.signup('real@test.dev', 'sol');
  const bot = await h.signup('bot@test.dev', 'robo');
  await h.admin();
  await h.q(`update auth.users set created_at = now() - interval '2 hours' where id in ($1, $2, $3)`, [stale, real, bot]);
  await h.q(`update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where id = $1`, [real]);
  await h.q(`insert into bots values ($1)`, [bot]);

  h.eq('a stale unconfirmed name is free', await taken('LUNA'), false);
  h.eq('an unconfirmed one from minutes ago is still taken', await taken('mars'), true);
  h.eq('a confirmed account keeps its name', await taken('sol'), true);
  h.eq('a bot keeps its name', await taken('robo'), true);
  h.eq('a name nobody has is free', await taken('nobody'), false);

  const again = await h.signup('right@test.dev', 'Luna');
  await h.admin();
  h.eq('the new sign-up gets the name', await nameOf(again), 'Luna');
  h.eq('the stale one gets a placeholder', /^user_[0-9a-f]{12}$/.test(await nameOf(stale)), true);
  const other = await h.signup('other@test.dev', 'mars');
  await h.admin();
  h.eq('a fresh unconfirmed name is not taken over', await nameOf(other), 'mars1');
  h.eq('and mars keeps it', await nameOf(fresh), 'mars');
  const solo = await h.signup('two@test.dev', 'sol');
  await h.admin();
  h.eq('a confirmed name is not taken over', await nameOf(solo), 'sol1');
  await h.as(real);
  await h.fails('members cannot call srv_username_taken', `select srv_username_taken('x')`);
  await h.fails('or username_stale_hold', `select username_stale_hold('${real}')`);
}
