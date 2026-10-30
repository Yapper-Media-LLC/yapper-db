// 662: a bot with an Administrator role sees private channels (bot_channel_visible's plain branch), like people do.
// Later tables and helpers the function reads get small stand-ins.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '662_bot_admin_private_channels.sql'), 'utf8');

const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists parent_id uuid;
alter table public.channels add column if not exists category_id uuid;
create table if not exists public.bot_servers (bot_id uuid, server_id uuid);
create table if not exists public.feature_flags (key text primary key, mode text, servers uuid[] default '{}', users uuid[] default '{}');
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql as $$ select base $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`662 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('662 runs', () => h.db.exec(MIG));
  await h.ok('662 re-runs cleanly', () => h.db.exec(MIG));
  const owner = await h.signup('own662@x.test', 'own662');
  const bot = await h.signup('bot662@x.test', 'bot662');
  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('s662', $1) returning id`, [owner])).id;
  await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, owner, bot]);
  await h.db.query(`insert into public.bot_servers values ($1, $2)`, [bot, sid]);
  const cols = (await h.q(`select column_name from information_schema.columns where table_name = 'channels' and table_schema = 'public'`)).map((r) => r.column_name);
  if (!cols.includes('server_id') || !cols.includes('private')) throw new Error('channels lacks server_id/private at base 24');
  const priv = (await h.one(`insert into public.channels (kind, name, server_id, private) values ('text', 'secret', $1, true) returning id`, [sid])).id;
  const pub = (await h.one(`insert into public.channels (kind, name, server_id, private) values ('text', 'general', $1, false) returning id`, [sid])).id;
  const sees = async (c) => (await h.one(`select public.bot_channel_visible($1, $2) v`, [bot, c])).v;
  h.eq('public channel: visible', await sees(pub), true);
  h.eq('private channel, plain role: hidden', await sees(priv), false);
  const plainRole = (await h.one(`insert into public.roles (server_id, name, perms) values ($1, 'helper', '{"send_messages": true}') returning id`, [sid])).id;
  await h.db.query(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, bot, plainRole]);
  h.eq('still hidden with a role that has no Administrator', await sees(priv), false);
  const adminRole = (await h.one(`insert into public.roles (server_id, name, perms) values ($1, 'admin', '{"administrator": true}') returning id`, [sid])).id;
  await h.db.query(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, bot, adminRole]);
  h.eq('private channel, Administrator role: visible', await sees(priv), true);
  const other = (await h.one(`insert into public.servers (name, owner_id) values ('o662', $1) returning id`, [owner])).id;
  const otherPriv = (await h.one(`insert into public.channels (kind, name, server_id, private) values ('text', 'x', $1, true) returning id`, [other])).id;
  await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [other, bot]);
  await h.db.query(`insert into public.bot_servers values ($1, $2)`, [bot, other]);
  h.eq('Administrator in one server does not open private channels in another', await sees(otherPriv), false);
  await h.db.query(`update public.bot_servers set server_id = $1 where bot_id = $2 and server_id = $3`, [other, bot, sid]);
  h.eq('removed from the server: hidden even with the role row left', await sees(priv), false);
}
