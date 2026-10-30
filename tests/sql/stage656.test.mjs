// 656: changing someone else's nickname needs Manage Nicknames AND to outrank them (public.outranks).
// The live set_nickname leans on later helpers, so they get small stand-ins driven by a table.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '656_nickname_hierarchy.sql'), 'utf8');

const STANDINS = String.raw`
alter table public.server_members add column if not exists nickname text;
create table public.t656 (k text primary key, v boolean);
grant select on public.t656 to authenticated;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql as $$ select true $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql security definer as $$ select coalesce((select v from public.t656 where k = perm), false) $$;
create or replace function public.outranks(sid uuid, target uuid) returns boolean language sql security definer as $$ select coalesce((select v from public.t656 where k = 'outranks'), false) $$;
create or replace function public.clean_name(t text) returns text language sql as $$ select nullif(btrim(t), '') $$;
create or replace function public.bad_name(t text) returns boolean language sql as $$ select false $$;
create or replace function public.has_adult_link(t text) returns boolean language sql as $$ select false $$;
create or replace function public.brand_name(t text) returns boolean language sql as $$ select false $$;
create or replace function public.is_site_admin() returns boolean language sql as $$ select false $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`656 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('656 runs', () => h.db.exec(MIG));
  await h.ok('656 re-runs cleanly', () => h.db.exec(MIG));
  const mod = await h.signup('mod656@x.test', 'mod656');
  const boss = await h.signup('boss656@x.test', 'boss656');
  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('s656', $1) returning id`, [boss])).id;
  await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, mod, boss]);
  const set = (k, v) => h.db.query(`insert into public.t656 values ($1, $2) on conflict (k) do update set v = excluded.v`, [k, v]);
  const nickOf = async (u) => (await h.one(`select nickname from public.server_members where server_id = $1 and user_id = $2`, [sid, u])).nickname;

  await set('manage_nicknames', true); await set('change_nickname', true); await set('outranks', false);
  await h.as(mod);
  await h.fails('manage_nicknames but below them: refused', `select public.set_nickname($1, $2, 'lol')`, [sid, boss]);
  await h.admin(); h.eq('their nickname untouched', await nickOf(boss), null);

  await set('outranks', true);
  await h.as(mod);
  await h.ok('manage_nicknames and above them: allowed', () => h.db.query(`select public.set_nickname($1, $2, 'Boss')`, [sid, boss]));
  await h.admin(); h.eq('nickname set', await nickOf(boss), 'Boss');

  await set('manage_nicknames', false);
  await h.as(mod);
  await h.fails('above them but no manage_nicknames: refused', `select public.set_nickname($1, $2, 'x')`, [sid, boss]);

  await set('outranks', false);
  await h.as(mod);
  await h.ok('own nickname needs no rank', () => h.db.query(`select public.set_nickname($1, $2, 'Me')`, [sid, mod]));
  await h.admin(); h.eq('own nickname set', await nickOf(mod), 'Me');
  await set('change_nickname', false);
  await h.as(mod);
  await h.fails('own nickname without change_nickname: refused', `select public.set_nickname($1, $2, 'Me2')`, [sid, mod]);
  await h.admin();
}
