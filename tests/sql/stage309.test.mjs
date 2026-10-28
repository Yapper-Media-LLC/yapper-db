// 309: share an unverified bot by its ID (flag bot_share_add). With the flag off nothing changes: only the maker adds an
// unverified bot. With it on, any server manager can add one its maker made shareable (only the maker can), up to 10
// servers the maker didn't add it to; re-adding where it
// already is never trips the cap; a site-banned maker's bot can't be shared; verified bots and Manage Server work as before.
// Starts from stage 24 + flags (031, 041), with stand-ins for the live bots tables and is_site_banned.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '309_bot_share_add.sql'), 'utf8');

const STANDINS = `
create table if not exists public.bots (
  id uuid primary key references public.profiles(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null, description text not null default '', public boolean not null default false,
  verified_at timestamptz, unlisted boolean not null default false
);
alter table public.bots enable row level security;
create policy "bots visible" on public.bots for select to authenticated using (owner_id = auth.uid() or public);
revoke all on public.bots from anon, authenticated;
grant select (id, owner_id, name, description, public, verified_at, unlisted) on public.bots to authenticated;
create table if not exists public.bot_servers (
  bot_id uuid not null references public.bots(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  added_by uuid, added_at timestamptz not null default now(),
  primary key (bot_id, server_id)
);
create table if not exists public.banned_standin (user_id uuid primary key);
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.banned_standin where user_id = uid) $$;
insert into public.feature_flags (key, label, description, mode) values ('bot_api', 'Bot API', 'Bots', 'everyone') on conflict (key) do update set mode = 'everyone';
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('309 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test mode', (await h.one(`select mode from feature_flags where key = 'bot_share_add'`)).mode, 'test');

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  const bot = await h.signup('bot@test.dev', 'newbot');
  const vbot = await h.signup('vbot@test.dev', 'vbot');
  await h.admin();
  await h.q(`insert into bots (id, owner_id, name) values ($1, $2, 'newbot')`, [bot, amy]);
  await h.q(`insert into bots (id, owner_id, name, public, verified_at) values ($1, $2, 'vbot', true, now())`, [vbot, amy]);

  await h.as(amy);
  const amys = (await h.one(`select create_server('Amys', null) id`)).id;
  await h.as(bob);
  const bobs = (await h.one(`select create_server('Bobs', null) id`)).id;
  const bobs2 = (await h.one(`select create_server('Bobs 2', null) id`)).id;
  await h.as(cat);
  const cats = (await h.one(`select create_server('Cats', null) id`)).id;

  // Flag off (test mode, none of these servers or users listed): same as before.
  await h.as(amy);
  await h.ok('the maker adds their own unverified bot', () => h.q(`select bot_add_to_server($1, $2)`, [bot, amys]));
  await h.as(bob);
  await h.fails('flag off: someone else still can not', `select bot_add_to_server($1, $2)`, [bot, bobs]);
  await h.ok('a verified bot works for anyone', () => h.q(`select bot_add_to_server($1, $2)`, [vbot, bobs]));

  await h.as(amy);
  await h.fails('flag off: the maker can not switch sharing on yet', `select bot_set_shareable($1, true)`, [bot]);

  // Flag on for everyone.
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'bot_share_add'`);
  await h.as(bob);
  await h.fails('flag on but not shareable: still refused', `select bot_add_to_server($1, $2)`, [bot, bobs]);
  await h.fails('only the maker can make it shareable', `select bot_set_shareable($1, true)`, [bot]);
  await h.admin();
  h.eq('so it stayed off', (await h.one(`select shareable from bots where id = $1`, [bot])).shareable, false);
  await h.as(amy);
  await h.ok('the maker switches sharing on', () => h.q(`select bot_set_shareable($1, true)`, [bot]));
  h.eq('the maker can read it', (await h.one(`select shareable from bots where id = $1`, [bot])).shareable, true);
  await h.fails('nobody can set it directly', `update bots set shareable = false where id = $1`, [bot]);
  await h.as(bob);
  await h.ok('flag on: a server manager adds it by ID', () => h.q(`select bot_add_to_server($1, $2)`, [bot, bobs]));
  await h.admin();
  h.eq('it joined as a member, added by bob', (await h.one(
    `select (select added_by from bot_servers where bot_id = $1 and server_id = $2) = $3 as by_bob,
            exists (select 1 from server_members where server_id = $2 and user_id = $1) as member`, [bot, bobs, bob])),
    { by_bob: true, member: true });
  await h.as(cat);
  await h.fails('still needs Manage Server', `select bot_add_to_server($1, $2)`, [bot, bobs2]);
  await h.fails('an unknown bot ID is refused', `select bot_add_to_server(gen_random_uuid(), $1)`, [cats]);

  // Banned maker.
  await h.admin();
  await h.q(`insert into banned_standin values ($1)`, [amy]);
  await h.as(cat);
  await h.fails('a banned maker’s bot can not be shared', `select bot_add_to_server($1, $2)`, [bot, cats]);
  await h.admin();
  await h.q(`delete from banned_standin where user_id = $1`, [amy]);

  // The cap: 10 servers the maker didn't add it to. bobs is 1, add 9 more by other people.
  await h.admin();
  const owners = [];
  for (let i = 0; i < 9; i++) owners.push(await h.signup(`o${i}@test.dev`, `o${i}`));
  for (let i = 0; i < 9; i++) {
    await h.as(owners[i]);
    const s = (await h.one(`select create_server($1, null) id`, [`S${i}`])).id;
    await h.q(`select bot_add_to_server($1, $2)`, [bot, s]);
  }
  await h.admin();
  h.eq('10 shared servers now', (await h.one(`select count(*)::int n from bot_servers where bot_id = $1 and added_by <> $2`, [bot, amy])).n, 10);
  await h.as(cat);
  await h.fails('the 11th is refused', `select bot_add_to_server($1, $2)`, [bot, cats]);
  await h.as(bob);
  await h.ok('re-adding where it already is is fine', () => h.q(`select bot_add_to_server($1, $2)`, [bot, bobs]));
  await h.as(amy);
  const amys2 = (await h.one(`select create_server('Amys 2', null) id`)).id;
  await h.ok('the maker is never capped', () => h.q(`select bot_add_to_server($1, $2)`, [bot, amys2]));
  await h.as(cat);
  await h.ok('verified bots are not capped', () => h.q(`select bot_add_to_server($1, $2)`, [vbot, cats]));

  // Sharing off again: no new servers, the ones it's in stay.
  await h.as(amy);
  await h.q(`select bot_set_shareable($1, false)`, [bot]);
  await h.admin();
  await h.q(`delete from bot_servers where bot_id = $1 and server_id = $2`, [bot, bobs]);
  await h.as(bob);
  await h.fails('sharing off: refused again', `select bot_add_to_server($1, $2)`, [bot, bobs]);
  await h.admin();
  h.eq('the other servers keep it', (await h.one(`select count(*)::int n from bot_servers where bot_id = $1 and added_by <> $2`, [bot, amy])).n, 9);

  // Once verified, the cap is gone.
  await h.admin();
  await h.q(`update bots set public = true, verified_at = now() where id = $1`, [bot]);
  await h.as(cat);
  await h.ok('verified now: the 11th works', () => h.q(`select bot_add_to_server($1, $2)`, [bot, cats]));

  await h.admin();
  h.eq('anon can not set sharing', (await h.one(`select has_function_privilege('anon', 'public.bot_set_shareable(uuid, boolean)', 'execute') ok`)).ok, false);
  h.eq('authenticated can still call it', (await h.one(`select has_function_privilege('authenticated', 'public.bot_add_to_server(uuid, uuid)', 'execute') ok`)).ok, true);
}
