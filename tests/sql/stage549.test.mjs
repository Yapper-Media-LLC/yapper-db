// 549: short usernames (4 characters or fewer) on idle accounts are released, and claiming one needs a week-old
// account with 10 messages, or Plus (flag short_name_guard). Same base as 529 (001..024, flags 031/041, 246 holds)
// with stand-ins for the live pieces (staff tables, bots, user_devices, mod_log, plus/verified columns).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const ANTIC = '00000000-0000-4000-8000-00000000a001';
const STANDINS = `
alter table auth.users add column if not exists last_sign_in_at timestamptz;
alter table public.profiles add column if not exists verified_as text;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (user_id uuid primary key);
create table if not exists public.user_devices (user_id uuid not null, kind text not null, h text not null,
  first_seen timestamptz not null default now(), last_seen timestamptz not null default now(), primary key (user_id, kind, h));
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
alter table public.messages disable trigger user;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('246_username_holds.sql'));
  const MIG = mig('549_short_name_guard.sql');
  await h.db.exec(MIG);
  await h.ok('549 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag row is test', (await h.one(`select mode from feature_flags where key = 'short_name_guard'`)).mode, 'test');

  await h.db.query(`insert into auth.users (id, email, raw_user_meta_data) values ($1, 'antic@test.dev', '{"username":"an"}')`, [ANTIC]);
  const name = async (id) => (await h.one(`select username from profiles where id = $1`, [id])).username;
  const old = (id, days) => h.q(`update profiles set created_at = now() - make_interval(days => $2) where id = $1`, [id, days]);
  const chan = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'x') returning id`)).id;
  const talk = (id, n) => h.q(`insert into messages (channel_id, author_id, content) select $1, $2, 'hi' from generate_series(1, $3)`, [chan, id, n]);

  // ---------- 1. release ----------
  const idle = await h.signup('idle@test.dev', 'work');      // hoarded: idle 30 days, 3 messages
  const chatty = await h.signup('chat@test.dev', 'chat');    // idle but 20 messages
  const seen = await h.signup('seen@test.dev', 'seen');      // app opened 2 days ago (user_devices)
  const login = await h.signup('login@test.dev', 'logn');    // signed in 3 days ago
  const young = await h.signup('young@test.dev', 'new');     // account 5 days old
  const longer = await h.signup('long@test.dev', 'hello');   // 5 characters
  const plus = await h.signup('plus@test.dev', 'plus');      // Plus
  const ver = await h.signup('ver@test.dev', 'vrfd');        // verified
  const mod = await h.signup('mod@test.dev', 'modd');        // moderator
  const banned = await h.signup('ban@test.dev', 'bann');     // site-banned
  const bot = await h.signup('bot@test.dev', 'bot');         // bot
  const held = await h.signup('held@test.dev', 'held');      // idle, holds its own old name
  await h.admin();
  for (const id of [idle, chatty, seen, login, young, longer, plus, ver, mod, banned, bot, held]) await old(id, 30);
  await old(young, 5);
  await talk(idle, 3);
  await talk(chatty, 20);
  await h.q(`insert into user_devices (user_id, kind, h, last_seen) values ($1, 'dev', 'x', now() - interval '2 days')`, [seen]);
  await h.q(`update auth.users set last_sign_in_at = now() - interval '3 days' where id = $1`, [login]);
  await h.q(`update profiles set plus_until = now() + interval '30 days' where id = $1`, [plus]);
  await h.q(`update profiles set verified_as = 'YouTube · vrfd' where id = $1`, [ver]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'spam')`, [banned]);
  await h.q(`insert into bots (id) values ($1)`, [bot]);
  await h.q(`insert into username_holds (name_key, user_id, until) values ('held', $1, now() + interval '5 days')`, [held]);

  const preview = await h.q(`select username, messages from release_short_names(true) order by 1`);
  h.eq('dry run lists only the hoarded names, in any mode', preview, [{ username: 'held', messages: 0 }, { username: 'work', messages: 3 }]);
  h.eq('a dry run changes nothing', await name(idle), 'work');

  await h.q(`select release_short_names()`);
  h.eq('test mode leaves people outside the test alone', await name(idle), 'work');
  await h.q(`update feature_flags set users = array_append(users, $1::uuid) where key = 'short_name_guard'`, [idle]);
  await h.q(`select release_short_names()`);
  h.eq('test mode renames a tester', (await name(idle)).startsWith('user'), true);
  h.eq('...but nobody else', await name(held), 'held');

  await h.q(`update feature_flags set mode = 'everyone' where key = 'short_name_guard'`);
  const n = (await h.q(`select user_id from release_short_names()`)).length;
  h.eq('everyone: the remaining hoarded name goes', n, 1);
  h.eq('held is renamed to userXXXXXXXX', /^user[0-9a-f]{8}$/.test(await name(held)), true);
  h.eq('its own hold on the name is ended', (await h.q(`select 1 from username_holds where name_key = 'held' and until > now()`)).length, 0);
  for (const [id, was] of [[chatty, 'chat'], [seen, 'seen'], [login, 'logn'], [young, 'new'], [longer, 'hello'], [plus, 'plus'], [ver, 'vrfd'], [mod, 'modd'], [banned, 'bann'], [bot, 'bot']]) {
    h.eq(`${was} is left alone`, await name(id), was);
  }
  h.eq('Antic keeps his name', await name(ANTIC), 'an');
  h.eq('one mod_log row per release, by Antic',
    (await h.q(`select 1 from mod_log where action = 'short_name_release' and actor = $1`, [ANTIC])).length, 2);
  h.eq('a second run finds nothing', (await h.q(`select 1 from release_short_names()`)).length, 0);
  await h.q(`update feature_flags set mode = 'off' where key = 'short_name_guard'`);
  await h.q(`insert into username_holds (name_key, user_id, until) values ('work', $1, now() + interval '5 days')`, [held]);
  await h.q(`update profiles set username = 'work' where id = $1`, [held]);
  h.eq('off: nothing is released', (await h.q(`select 1 from release_short_names()`)).length, 0);
  h.eq('off: the dry run still lists', (await h.q(`select 1 from release_short_names(true)`)).length, 1);

  // ---------- 2. claim ----------
  await h.q(`update feature_flags set mode = 'everyone' where key = 'short_name_guard'`);
  const fresh = await h.signup('fresh@test.dev', 'freshone');   // new account
  const weekOld = await h.signup('week@test.dev', 'weekone');   // 8 days, 10 messages
  const quiet = await h.signup('quiet@test.dev', 'quietone');   // 8 days, 9 messages
  const paid = await h.signup('paid@test.dev', 'paidone');      // new, Plus
  const staff = await h.signup('staff@test.dev', 'staffone');   // new, moderator
  await h.admin();
  await old(weekOld, 8); await old(quiet, 8);
  await talk(weekOld, 10); await talk(quiet, 9); await talk(fresh, 50);
  await h.q(`update profiles set plus_until = now() + interval '1 day' where id = $1`, [paid]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  const GATE = 'Short names (4 letters or less) are for accounts that are a week old with 10 messages sent, or have Plus.';
  const rename = async (id, to) => {
    await h.as(id);
    let msg = null;
    try { await h.db.query(`update profiles set username = $2 where id = $1`, [id, to]); } catch (e) { msg = e.message; }
    await h.admin();
    return msg;
  };
  h.eq('a new account can\'t take a 4-letter name', await rename(fresh, 'snip'), GATE);
  h.eq('a new account can\'t take a 2-letter name', await rename(fresh, 'ab'), GATE);
  h.eq('a new account can take a 5-letter name', await rename(fresh, 'fiver'), null);
  h.eq('8 days old with 9 messages: no', await rename(quiet, 'nope'), GATE);
  h.eq('8 days old with 10 messages: yes', await rename(weekOld, 'mine'), null);
  h.eq('changing the case of your own short name is fine', await rename(weekOld, 'Mine'), null);
  h.eq('Plus skips the wait', await rename(paid, 'gold'), null);
  h.eq('staff skip it', await rename(staff, 'crew'), null);
  // A released account can't take a short name back for 30 days, even with enough messages or Plus.
  await talk(idle, 12);
  await h.q(`update profiles set plus_until = now() + interval '1 day' where id = $1`, [idle]);
  h.eq('a released account can\'t reclaim a short name', (await rename(idle, 'work') ?? '').startsWith('A short name of yours was released'), true);
  h.eq('...but can take a longer one', await rename(idle, 'worker'), null);
  await h.q(`update mod_log set created_at = now() - interval '31 days' where action = 'short_name_release' and target_id = $1`, [idle]);
  h.eq('after 30 days it can', await rename(idle, 'wrk'), null);
  await h.q(`update feature_flags set mode = 'test' where key = 'short_name_guard'`);
  h.eq('test mode: people outside the test aren\'t gated', await rename(fresh, 'free'), null);
  await h.q(`update feature_flags set users = array_append(users, $1::uuid) where key = 'short_name_guard'`, [fresh]);
  h.eq('test mode: testers are', await rename(fresh, 'four'), GATE);
  await h.q(`update feature_flags set mode = 'off' where key = 'short_name_guard'`);
  h.eq('off: nobody is', await rename(fresh, 'four'), null);
  await h.admin();
  await h.ok('server-side renames go through in any mode', async () => {
    await h.q(`update feature_flags set mode = 'everyone' where key = 'short_name_guard'`);
    await h.q(`update profiles set username = 'srv' where id = $1`, [quiet]);
  });

  // ---------- sign-up ----------
  h.eq('srv_short_name_blocked: short name, flag everyone', (await h.one(`select srv_short_name_blocked('abcd') b`)).b, true);
  h.eq('srv_short_name_blocked: 5 letters', (await h.one(`select srv_short_name_blocked('abcde') b`)).b, false);
  const late = await h.signup('late@test.dev', 'late');
  h.eq('a sign-up with a short name gets userXXXXXXXX once the flag is everyone', /^user[0-9a-f]{8}$/.test(await name(late)), true);
  const botSignup = (await h.q(`insert into auth.users (email, raw_user_meta_data) values ('b2@test.dev', '{"username":"Yap","bot":true}') returning id`))[0].id;
  h.eq('a bot keeps its short name', await name(botSignup), 'Yap');
  await h.q(`update feature_flags set mode = 'test' where key = 'short_name_guard'`);
  h.eq('srv_short_name_blocked: flag test', (await h.one(`select srv_short_name_blocked('abcd') b`)).b, false);
  const tester = await h.signup('t2@test.dev', 'abcd');
  h.eq('test mode: sign-ups keep short names', await name(tester), 'abcd');

  // Grants: the release and the guard are not callable by users.
  await h.as(fresh);
  await h.fails('a user can\'t call release_short_names', `select release_short_names()`);
  await h.fails('a user can\'t call srv_short_name_blocked', `select srv_short_name_blocked('ab')`);
  await h.admin();
}
