// 642: Gift Plus to anyone (flag gift_anyone). Base 24 (profiles, friendships, blocks, site_bans) + the flag
// functions (031/041), stand-ins for the live bits 642 reads (people_search_quota from 141, bots / bot_accounts,
// site_bans.expires_at + the 029 is_site_banned), then 642 twice (re-runnable).
// Checks: gift_search finds anyone by username prefix (friends by substring too), never me, bots, banned or blocked
// (either way) accounts, needs both flags, shares search_people's quota; gift_plus_check gives the right reason and
// only the service role can call it; the flag row is in test mode for HQ + Antic.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;
create table if not exists public.bots (id uuid primary key references public.profiles(id) on delete cascade);
create table if not exists public.bot_accounts (user_id uuid primary key references public.profiles(id) on delete cascade);
create table if not exists public.people_search_quota (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  minute_start timestamptz not null default now(), minute_n int not null default 0,
  hour_start timestamptz not null default now(), hour_n int not null default 0);
alter table public.people_search_quota enable row level security;
revoke all on public.people_search_quota from anon, authenticated;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '642_gift_anyone.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('642 re-runs cleanly', () => h.db.exec(MIG));

  const HQ = '00000000-0000-4000-8000-00000000b001';
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'gift_anyone'`);
  h.eq('flag in test mode for HQ', [flag.mode, flag.servers], ['test', [HQ]]);
  h.eq('Antic in the flag', flag.users, ['00000000-0000-4000-8000-00000000a001']);

  const amy = await h.signup('amy642@test.dev', 'amy642');
  const bob = await h.signup('bob642@test.dev', 'bob642');     // a friend
  const cat = await h.signup('cat642@test.dev', 'cat642');     // a stranger
  const dan = await h.signup('dan642@test.dev', 'dan642');     // blocked by amy
  const eve = await h.signup('eve642@test.dev', 'eve642');     // blocked amy
  const fay = await h.signup('fay642@test.dev', 'fay642');     // banned
  const gus = await h.signup('gus642@test.dev', 'gus642');     // a bot
  const hal = await h.signup('hal642@test.dev', 'hal642');     // an in-house bot account
  const yz = await h.signup('yz642@test.dev', 'yz');            // 2-letter username
  const zed = await h.signup('zed642@test.dev', 'zed642');     // not in the flag
  const S = (await h.one(`insert into servers (name, owner_id) values ('HQ', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, amy]);
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'gift_anyone'`, [S]);
  await h.q(`insert into feature_flags (key, label, mode, servers) values ('gift_plus', 'Gift Plus', 'test', array[$1]::uuid[])
    on conflict (key) do update set mode = 'test', servers = array[$1]::uuid[]`, [S]);
  await h.q(`update profiles set display_name = 'Catherine' where id = $1`, [cat]);
  await h.q(`update profiles set display_name = 'Bobby Tables' where id = $1`, [bob]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'test')`, [fay]);
  await h.q(`insert into bots (id) values ($1)`, [gus]);
  await h.q(`insert into bot_accounts (user_id) values ($1)`, [hal]);

  await h.as(amy);
  await h.q(`select send_friend_request('bob642')`);
  await h.as(bob);
  await h.q(`select respond_friend_request($1, true)`, [amy]);
  await h.as(amy);
  await h.q(`select block_user($1)`, [dan]);
  await h.as(eve);
  await h.q(`select block_user($1)`, [amy]);

  const names = async (q) => (await h.q(`select username, friend from gift_search($1)`, [q]));
  await h.as(amy);
  h.eq('friends match by substring, strangers only by prefix', await names('642'), [{ username: 'bob642', friend: true }]);
  h.eq('prefix search by username', await names('cat'), [{ username: 'cat642', friend: false }]);
  h.eq('friend by display name substring', await names('tables'), [{ username: 'bob642', friend: true }]);
  h.eq('stranger display names are not searched', await names('cather'), []);
  h.eq('a 2-letter query only finds that exact username', await names('yz'), [{ username: 'yz', friend: false }]);
  h.eq('a 2-letter query is not a prefix search', await names('ca'), []);
  h.eq('never me', await names('amy'), []);
  h.eq('not someone I blocked', await names('dan'), []);
  h.eq('not someone who blocked me', await names('eve'), []);
  h.eq('not a banned account', await names('fay'), []);
  h.eq('not a bot', await names('gus'), []);
  h.eq('not an in-house bot account', await names('hal'), []);
  h.eq('@ and case are ignored', await names('@CAT6'), [{ username: 'cat642', friend: false }]);
  h.eq('row shape', Object.keys((await h.q(`select * from gift_search('cat')`))[0]).sort(), ['avatar_path', 'display_name', 'friend', 'id', 'username']);

  // Quota shared with search_people: 20 a minute, then a clear error.
  await h.admin();
  await h.q(`update people_search_quota set minute_n = 20 where user_id = $1`, [amy]);
  await h.as(amy);
  await h.fails('21st search in a minute is refused', `select * from gift_search('cat')`);

  // Both flags needed.
  await h.as(zed);
  h.eq('off for someone outside the flag', await names('cat'), []);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'gift_anyone'`);
  await h.q(`update people_search_quota set minute_n = 0 where user_id = $1`, [amy]);
  await h.as(amy);
  h.eq('off when gift_anyone is off', await names('cat'), []);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'gift_anyone'`);
  await h.q(`update feature_flags set mode = 'off' where key = 'gift_plus'`);
  await h.as(amy);
  h.eq('off when gift_plus is off', await names('cat'), []);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'gift_plus'`);
  await h.as(zed);
  h.eq('on for everyone once published', await names('cat'), [{ username: 'cat642', friend: false }]);
  await h.as(fay);
  h.eq('a banned account gets nothing', await names('cat'), []);
  await h.as(null);
  await h.fails('anon cannot search', `select * from gift_search('cat')`);

  // gift_plus_check: service role only, one reason each.
  await h.as(amy);
  await h.fails('users cannot call gift_plus_check', `select gift_plus_check($1, $2)`, [amy, cat]);
  await h.admin();
  await h.db.exec(`set role service_role;`);
  const why = async (a, b) => (await h.one(`select gift_plus_check($1, $2) r`, [a, b])).r;
  h.eq('stranger is fine', await why(amy, cat), null);
  h.eq('friend is fine', await why(amy, bob), null);
  h.eq('self', await why(amy, amy), 'self');
  h.eq('unknown', await why(amy, '00000000-0000-0000-0000-000000000000'), 'not_found');
  h.eq('bot', await why(amy, gus), 'bot');
  h.eq('bot account', await why(amy, hal), 'bot');
  h.eq('banned recipient', await why(amy, fay), 'banned');
  h.eq('banned gifter', await why(fay, amy), 'gifter_banned');
  h.eq('I blocked them', await why(amy, dan), 'blocked');
  h.eq('they blocked me', await why(amy, eve), 'blocked');
  await h.db.exec(`reset role;`);
}
