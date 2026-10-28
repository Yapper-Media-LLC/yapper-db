// 423: without Add Reactions you can still click a reaction that's already on the message, but not add a new emoji.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '423_react_existing.sql'), 'utf8');

// channel_allows reads a stand-in table of channels where Add Reactions is off; reaction roles are a table too.
const STANDINS = `
create table if not exists public.no_react (channel_id uuid primary key);
create table if not exists public.reaction_roles (message_id uuid, emoji text);
create or replace function public.message_channel(mid uuid) returns uuid language sql stable security definer set search_path = public as $f$
  select channel_id from public.messages where id = mid $f$;
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $f$
  select not (perm = 'add_reactions' and exists (select 1 from public.no_react where channel_id = cid)) $f$;
create or replace function public.dm_blocked(cid uuid) returns boolean language sql stable as $f$ select false $f$;
create or replace function public.is_reaction_role(mid uuid, e text) returns boolean language sql stable security definer set search_path = public as $f$
  select exists (select 1 from public.reaction_roles where message_id = mid and emoji = e) $f$;
grant select, insert, delete on public.reactions to authenticated;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('423 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  // Old accounts, so the new-account message pace doesn't trip.
  await h.q("update profiles set created_at = now() - interval '30 days'");
  const ch = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'k1') returning id`)).id;
  const other = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'k2') returning id`)).id;
  await h.q(`insert into channel_members values ($1, $2), ($1, $3), ($4, $2)`, [ch, amy, bob, other]);
  const msg = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'rules') returning id`, [ch, amy])).id;
  const hidden = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'secret') returning id`, [other, amy])).id;
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, '✅'), ($3, $2, '👀')`, [msg, amy, hidden]);
  await h.q(`insert into no_react values ($1)`, [ch]);

  await h.as(bob);
  await h.ok('bob joins the ✅ already there', () => h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, '✅')`, [msg, bob]));
  await h.fails('bob cannot add a new emoji', `insert into reactions (message_id, user_id, emoji) values ('${msg}', '${bob}', '🔥')`);
  await h.ok('bob takes his back', () => h.q(`delete from reactions where message_id = $1 and user_id = $2`, [msg, bob]));
  await h.ok('and can click it again', () => h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, '✅')`, [msg, bob]));
  await h.fails('cannot react as someone else', `insert into reactions (message_id, user_id, emoji) values ('${msg}', '${amy}', '✅')`);
  h.eq('reaction_exists says nothing about a channel bob is not in', (await h.one(`select public.reaction_exists($1, '👀') x`, [hidden])).x, false);

  await h.as(cat);
  await h.fails('cat (not a member) cannot join it', `insert into reactions (message_id, user_id, emoji) values ('${msg}', '${cat}', '✅')`);

  await h.admin();
  await h.q(`delete from no_react`);
  await h.as(bob);
  await h.ok('with Add Reactions bob adds new ones as before', () => h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, '🔥')`, [msg, bob]));
}
