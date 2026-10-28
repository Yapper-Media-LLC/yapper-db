// 434: a server's custom invite link is let go when it drops under 5 people (bots don't count).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '434_vanity_below_five.sql'), 'utf8');

const STANDINS = `
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (user_id uuid primary key);
alter table public.invites add column if not exists vanity boolean not null default false;
`;

export default async function (h) {
  const ids = [];
  for (const n of ['amy', 'bob', 'cat', 'dan', 'eve', 'fay']) ids.push(await h.signup(`${n}@test.dev`, n));
  const bot = await h.signup('bot@test.dev', 'robo');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('434 re-runs cleanly', () => h.db.exec(MIG));
  await h.q(`insert into bots values ($1)`, [bot]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('club', $1) returning id`, [ids[0]])).id;
  // Joining the owner may already be automatic; add the rest (and the bot).
  for (const u of [...ids, bot]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u]);
  await h.q(`insert into invites (code, server_id, created_by, vanity) values ('clubby', $1, $2, true), ('plain123', $1, $2, false)`, [sid, ids[0]]);
  const has = async () => (await h.one(`select count(*)::int n from invites where server_id = $1 and vanity`, [sid])).n;
  const leave = (u) => h.q(`delete from server_members where server_id = $1 and user_id = $2`, [sid, u]);

  await leave(ids[5]);
  h.eq('5 people left: link kept', await has(), 1);
  await leave(ids[4]);
  h.eq('4 people (and a bot): link let go', await has(), 0);
  h.eq('the normal invite stays', (await h.one(`select count(*)::int n from invites where code = 'plain123'`)).n, 1);
  await h.ok('more leaves with no custom link are fine', () => leave(ids[3]));
}
