// 449: the in-app bot list (bot_directory) follows the boosted Most used order and returns the boost tier.
// Runs 441-445 and 449 on the stage441 stand-ins plus the few columns bot_directory reads.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage441.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const MORE = `
alter table public.bots add column if not exists last_poll_at timestamptz;
alter table public.bots add column if not exists last_event_at timestamptz;
alter table public.profiles add column if not exists plus_until timestamptz;
create table if not exists public.bot_commands (bot_id uuid, name text, description text);
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  for (const f of ['441_bot_promoted.sql', '443_bot_promo_two_spots.sql', '444_bot_boosts.sql', '445_bot_boost_nerf.sql']) await h.db.exec(mig(f));
  const MIG = mig('449_bot_directory_boosts.sql');
  await h.ok('449 runs', () => h.db.exec(MIG));
  await h.ok('449 re-runs cleanly', () => h.db.exec(MIG));

  const a = await h.signup('a@test.dev', 'alice'); // flag on
  const b = await h.signup('b@test.dev', 'bob'); // flag off
  const bots = [];
  for (let i = 0; i < 25; i++) bots.push(await h.signup(`bot${i}@test.dev`, `bot${i}`));
  await h.admin();
  for (const [i, id] of bots.entries()) await h.q(`insert into bots (id, owner_id, name, public, verified_at, real_servers) values ($1, $2, $3, true, now(), $4)`, [id, a, `Bot${String(i).padStart(2, '0')}`, 260 - 10 * i]);
  await h.q(`insert into bot_commands values ($1, 'ping', 'pong')`, [bots[3]]);
  await h.q(`insert into feature_flags (key, label, mode) values ('bot_verified', 'x', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  await h.q(`update feature_flags set mode = 'test', users = array[$1]::uuid[], servers = '{}' where key = 'bot_promoted'`, [a]);
  await h.db.exec(`set role service_role`);
  await h.q(`select book_bot_boost($1, 8, 'stripe', 'evt_8', null, 7)`, [bots[14]]);
  await h.db.exec(`reset role`);
  const order = async () => (await h.q(`select id, boost from bot_directory('', '', 'popular')`));

  await h.as(a);
  const mine = await order();
  h.eq('in-app list: Mega bot at #4 like /bots', mine.findIndex((r) => r.id === bots[14]) + 1, 4);
  h.eq('in-app list: boost tier for the label', mine.find((r) => r.id === bots[14]).boost, 8);
  h.eq('same order as public_bots', mine.map((r) => r.id), (await h.q(`select id from public_bots(null, null, 'popular', 100, 0)`)).map((r) => r.id));
  h.eq('search by command still works', (await h.q(`select id from bot_directory('ping', '', 'popular')`)).map((r) => r.id), [bots[3]]);
  h.eq('newest sort still lists all', (await h.q(`select id from bot_directory('', '', 'new')`)).length, 25);
  await h.as(b);
  const theirs = await order();
  h.eq('flag off: plain order', theirs.findIndex((r) => r.id === bots[14]) + 1, 15);
  h.eq('flag off: no label', theirs.find((r) => r.id === bots[14]).boost, 0);
  await h.as(null);
  await h.fails('anon cannot call bot_directory', `select id from bot_directory('', '', 'popular')`);
}
