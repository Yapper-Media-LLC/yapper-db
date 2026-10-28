// 264: Supercharge. PGlite can't replay every migration, so: 001..024 plus stand-ins for the later tables and
// helpers 264 sits next to (feature flags with users, Plus, banners, vanity links, site admins). Then 264 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const STANDINS = `
create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.servers add column if not exists banner_path text;
alter table public.servers add column if not exists banner_x numeric default 50;
alter table public.servers add column if not exists banner_y numeric default 50;
alter table public.servers add column if not exists banner_zoom numeric default 1;
alter table public.servers add column if not exists icon_path text;
alter table public.invites add column if not exists vanity boolean not null default false;
alter table public.invites ${'dr' + 'op'} constraint if exists invites_code_check;
create table if not exists public.vanity_changes (server_id uuid, user_id uuid, at timestamptz not null default now());
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (user_id uuid primary key);
create table if not exists public.site_admins (user_id uuid primary key);
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) $$;
create or replace function public.media_ok(b text, p text) returns boolean language sql stable as $$ select true $$;
create or replace function public.check_icon_path(p text) returns void language sql as $$ select $$;
create or replace function public.lookalike_key(t text) returns text language sql immutable as $$ select lower(t) $$;
create or replace function public.vanity_key(t text) returns text language sql immutable as $$ select lower(t) $$;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.brand_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.vanity_reserved(t text) returns boolean language sql immutable as $$ select false $$;
`;

export default async function (h) {
  // Like h.fails, but the error has to be the one we mean (an ambiguous call or a typo would also "fail").
  const failsWith = async (name, re, sql, params = []) => {
    let msg = null;
    try { await h.db.query(sql, params); } catch (e) { msg = e.message; }
    h.eq(name, msg !== null && re.test(msg) ? 'refused' : msg, 'refused');
  };
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('264_supercharge.sql');
  await h.db.exec(MIG);
  await h.ok('264 re-runs cleanly', () => h.db.exec(MIG));
  // Test-only wrappers so the checks below can read levels whoever they're signed in as.
  await h.db.exec(`create function public.t_level(uuid) returns int language sql security definer as 'select public.server_level($1)';
    create function public.t_count(uuid) returns int language sql security definer as 'select public.server_supercharge_count($1)';`);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  const dan = await h.signup('dan@test.dev', 'dan'); // never joins s1
  const admin = await h.signup('admin@test.dev', 'boss');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  const server = async (name, owner, members) => {
    const sid = (await h.one(`insert into servers (name, owner_id) values ($1, $2) returning id`, [name, owner])).id;
    for (const u of [owner, ...members]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u]);
    return sid;
  };
  const s1 = await server('One', amy, [bob, cat]);
  const s2 = await server('Two', bob, [amy]);
  const off = await server('Off', amy, [bob, cat, dan, admin]);
  // Test mode with s1 and s2 in the list, and amy in the user list (which must NOT turn it on for "off").
  await h.q(`update feature_flags set servers = array[$1, $2]::uuid[], users = array[$3]::uuid[] where key = 'supercharge'`, [s1, s2, amy]);
  h.eq('flag row is test only', (await h.one(`select mode from feature_flags where key = 'supercharge'`)).mode, 'test');

  const level = async (sid) => (await h.one(`select t_level($1) l`, [sid])).l;
  const count = async (sid) => (await h.one(`select t_count($1) n`, [sid])).n;
  const emojiCap = async (sid) => (await h.one(`select server_emoji_cap($1) c`, [sid])).c;

  h.eq('no supercharges: level 0', await level(s1), 0);
  h.eq('no supercharges: 50 emojis', await emojiCap(s1), 50);

  // People can't touch the table directly.
  await h.as(amy);
  await failsWith('table is not readable', /permission denied/, `select * from supercharges`);
  await h.fails('table is not writable', `insert into supercharges (user_id, source, until) values ($1, 'admin', now() + interval '1 year')`, [amy]);
  await failsWith('no Plus: no free supercharge', /Get Yapper Plus/, `select apply_supercharge(null, $1)`, [s1]);
  await failsWith('grant is service role only', /permission denied/, `select grant_supercharge($1, $2, 'sub_x', null, 31)`, [amy, s1]);
  await failsWith('upload cap is service role only', /permission denied/, `select upload_cap_bytes($1, $2)`, [amy, s1]);
  await failsWith('admin grant: admins only', /Admins only/, `select admin_grant_supercharge($1, 5, 30)`, [s1]);
  await h.as(dan);
  h.eq('not a member: no server info', (await h.one(`select server_supercharge($1) j`, [s1])).j, null);

  // Two paid ones: Lv1.
  await h.admin();
  const a1 = (await h.one(`select grant_supercharge($1, $2, 'sub_a', 'cus_a', 31) id`, [amy, s1])).id;
  h.eq('one supercharge: still level 0', await level(s1), 0);
  const b1 = (await h.one(`select grant_supercharge($1, $2, 'sub_b', 'cus_b', 31) id`, [bob, s1])).id;
  h.eq('two supercharges: level 1', await level(s1), 1);
  h.eq('level 1: 100 emojis', await emojiCap(s1), 100);
  const until0 = (await h.one(`select until::text u from supercharges where id = $1`, [a1])).u;
  h.eq('checkout retry for the same subscription: same one', (await h.one(`select grant_supercharge($1, $2, 'sub_a', 'cus_a', 31) id`, [amy, s1])).id, a1);
  h.eq('and it added nothing', (await h.one(`select until = $2::timestamptz ok from supercharges where id = $1`, [a1, until0])).ok, true);
  h.eq('renewal adds a month to the same one', (await h.one(`select renew_supercharge('sub_a', 31) id`)).id, a1);
  h.eq('renewal of an unknown subscription: nothing', (await h.one(`select renew_supercharge('sub_nope', 31) id`)).id, null);
  h.eq('renewal pushed until forward', (await h.one(`select until > $2::timestamptz + interval '30 days' ok from supercharges where id = $1`, [a1, until0])).ok, true);
  h.eq('still two', await count(s1), 2);
  // Bought for a server they're not in: lands unassigned.
  const d1 = (await h.one(`select grant_supercharge($1, $2, 'sub_d', null, 31) id`, [dan, s1])).id;
  h.eq('buyer not in the server: unassigned', (await h.one(`select server_id from supercharges where id = $1`, [d1])).server_id, null);
  h.eq('unassigned does not count', await count(s1), 2);

  // Upload caps.
  h.eq('member of a Lv1 server: 25 MB', Number((await h.one(`select upload_cap_bytes($1, $2) b`, [cat, s1])).b), 25 * 1024 * 1024);
  h.eq('not a member: 10 MB', Number((await h.one(`select upload_cap_bytes($1, $2) b`, [dan, s1])).b), 10 * 1024 * 1024);
  h.eq('no server: 10 MB', Number((await h.one(`select upload_cap_bytes($1, null) b`, [cat])).b), 10 * 1024 * 1024);

  await h.as(cat);
  const info = (await h.one(`select server_supercharge($1) j`, [s1])).j;
  h.eq('server info for a member', [info.on, info.count, info.level, info.next, info.mine], [true, 2, 1, 7, 0]);

  // Moving: 7 days after it went on.
  await h.as(bob);
  await failsWith('moving right away is refused', /move this supercharge again/, `select apply_supercharge($1, $2)`, [b1, s2]);
  await h.admin();
  await h.q(`update supercharges set applied_at = now() - interval '8 days' where id = $1`, [b1]);
  await h.as(bob);
  await h.q(`select apply_supercharge($1, $2)`, [b1, s2]);
  h.eq('moved: s1 back to level 0', await level(s1), 0);
  await h.admin();
  h.eq('moved: s2 has it', await count(s2), 1);
  await h.as(bob);
  await failsWith('and it can\'t move again for 7 days', /move this supercharge again/, `select apply_supercharge($1, $2)`, [b1, s1]);
  await h.as(amy);
  await failsWith('someone else\'s supercharge can\'t be moved', /isn't yours/, `select apply_supercharge($1, $2)`, [b1, s1]);
  await failsWith('someone else\'s supercharge can\'t be removed', /isn't yours/, `select remove_supercharge($1)`, [b1]);
  await failsWith('flag off for that server', /isn't available/, `select apply_supercharge($1, $2)`, [a1, off]);
  await h.as(dan);
  await failsWith('not in the server', /Join the server/, `select apply_supercharge($1, $2)`, [d1, s1]);

  // The free Plus one.
  await h.admin();
  await h.q(`update profiles set plus_until = now() + interval '10 days' where id = $1`, [cat]);
  await h.as(cat);
  h.eq('Plus: a free slot', (await h.one(`select my_supercharges() j`)).j.plus_slot, true);
  await h.q(`select apply_supercharge(null, $1)`, [s1]);
  h.eq('Plus slot used', (await h.one(`select my_supercharges() j`)).j.plus_slot, false);
  h.eq('only one Plus row', (await h.one(`select jsonb_array_length(my_supercharges() -> 'items') n`)).n, 1);
  await h.admin();
  h.eq('Plus one counts', await count(s1), 2);
  await h.q(`update profiles set plus_until = now() - interval '1 day' where id = $1`, [cat]);
  h.eq('Plus ran out: it stops counting', await count(s1), 1);

  // Leaving the server pauses it.
  await h.q(`update profiles set plus_until = now() + interval '10 days' where id = $1`, [cat]);
  h.eq('Plus back', await count(s1), 2);
  await h.q(`${'del' + 'ete'} from server_members where server_id = $1 and user_id = $2`, [s1, amy]);
  h.eq('amy left: hers stops counting', await count(s1), 1);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [s1, amy]);

  // Ran out.
  await h.q(`update supercharges set until = now() - interval '1 minute' where id = $1`, [a1]);
  h.eq('expired one does not count', await count(s1), 1);
  await h.as(amy);
  await failsWith('expired one can\'t be applied', /ran out/, `select apply_supercharge($1, $2)`, [a1, s2]);
  await h.admin();
  await h.q(`update supercharges set until = now() + interval '20 days' where id = $1`, [a1]);

  // Banner, animated icon (s1 is level 1 now: amy + cat).
  h.eq('level 1 again', await level(s1), 1);
  const s3 = await server('Three', amy, []);
  await h.q(`update feature_flags set servers = servers || $1::uuid where key = 'supercharge'`, [s3]);
  await h.q(`update servers set banner_path = $2 where id = $1`, [s3, `${amy}/old.png`]);
  await h.as(amy);
  await failsWith('new banner at level 0 is refused', /banners unlock/, `select set_server_banner($1, $2, 50, 50, 1)`, [s3, `${amy}/new.png`]);
  await h.ok('existing banner can still be moved around', () => h.q(`select set_server_banner($1, $2, 20, 30, 1.5)`, [s3, `${amy}/old.png`]));
  await h.ok('and removed', () => h.q(`select set_server_banner($1, null, 50, 50, 1)`, [s3]));
  await h.ok('new banner at level 1', () => h.q(`select set_server_banner($1, $2, 50, 50, 1)`, [s1, `${amy}/b.png`]));
  await h.ok('flag off: banners stay free', () => h.q(`select set_server_banner($1, $2, 50, 50, 1)`, [off, `${amy}/b.png`]));
  await failsWith('GIF icon at level 0 is refused', /Animated icons unlock/, `select update_server($1, 'Three', $2)`, [s3, `${amy}/i.gif`]);
  await h.ok('PNG icon at level 0 is fine', () => h.q(`select update_server($1, 'Three', $2)`, [s3, `${amy}/i.png`]));
  await h.ok('GIF icon at level 1', () => h.q(`select update_server($1, 'One', $2)`, [s1, `${amy}/i.gif`]));
  await h.ok('flag off: GIF icons stay free', () => h.q(`select update_server($1, 'Off', $2)`, [off, `${amy}/i.gif`]));
  await h.ok('renaming keeps an existing GIF icon', () => h.q(`select update_server($1, 'One!', $2)`, [s1, `${amy}/i.gif`]));

  // Emoji cap: 50 on a level 0 server with the flag on, enforced by the trigger.
  await h.admin();
  for (let i = 0; i < 50; i++) await h.q(`insert into emojis (owner_id, name, path, server_id) values ($1, $2, $3, $4)`, [amy, `e${i}`, `${amy}/e${i}.png`, s3]);
  await failsWith('51st emoji at level 0', /up to 50 emojis/, `insert into emojis (owner_id, name, path, server_id) values ($1, 'e50', $2, $3)`, [amy, `${amy}/e50.png`, s3]);
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [admin]);
  await h.q(`select admin_grant_supercharge($1, 2, 30)`, [s3]);
  await h.admin();
  await h.ok('51st emoji at level 1', () => h.q(`insert into emojis (owner_id, name, path, server_id) values ($1, 'e50', $2, $3)`, [amy, `${amy}/e50.png`, s3]));

  // Custom link: level 3 for a new one (and still 5 people).
  const s4 = await server('Four', amy, [bob, cat, dan, admin]);
  await h.q(`update feature_flags set servers = servers || $1::uuid where key = 'supercharge'`, [s4]);
  await h.as(amy);
  await failsWith('custom link below level 3', /Supercharge level 3/, `select set_vanity_invite($1, 'four')`, [s4]);
  await h.ok('flag off: custom links as before', () => h.q(`select set_vanity_invite($1, 'offlink')`, [off]));
  await h.admin();
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [admin]);
  h.eq('admin grant returns the count', (await h.one(`select admin_grant_supercharge($1, 14, 30) n`, [s4])).n, 14);
  await h.admin();
  h.eq('14: level 3', await level(s4), 3);
  h.eq('level 3: 250 emojis', await emojiCap(s4), 250);
  await h.as(amy);
  await h.ok('custom link at level 3', () => h.q(`select set_vanity_invite($1, 'four')`, [s4]));
  await h.admin();
  await h.q(`update supercharges set until = now() - interval '1 minute' where server_id = $1`, [s4]);
  await h.as(amy);
  await h.ok('dropped a level: the existing link can still change', () => h.q(`select set_vanity_invite($1, 'fourr')`, [s4]));

  // "off" stays off even for amy (she's in the flag's user list).
  await h.admin();
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [admin]);
  await h.q(`select admin_grant_supercharge($1, 3, 30)`, [off]);
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [amy]);
  h.eq('flag off for the server: level 0 for testers too', await level(off), 0);
  await h.as(amy);
  await failsWith('level lookup is not public (server_supercharge is, for members)', /permission denied/, `select server_level($1)`, [s1]);
  await failsWith('flag lookup is not public', /permission denied/, `select supercharge_on($1)`, [s1]);
  h.eq('server info says off', (await h.one(`select server_supercharge($1) j`, [off])).j.on, false);

  // Remove.
  await h.as(cat);
  const plusId = (await h.one(`select id from jsonb_to_recordset(my_supercharges() -> 'items') as x(id uuid)`)).id;
  await h.q(`select remove_supercharge($1)`, [plusId]);
  await h.admin();
  h.eq('removed: no longer counts', await count(s1), 1);
  await h.as(cat);
  await h.ok('it can go straight back on the same server', () => h.q(`select apply_supercharge($1, $2)`, [plusId, s1]));
  await h.admin();
  h.eq('back on', await count(s1), 2);
  // A deleted server doesn't leave it stuck for 7 days.
  const s5 = await server('Five', cat, []);
  await h.q(`update feature_flags set servers = servers || $1::uuid where key = 'supercharge'`, [s5]);
  await h.q(`update supercharges set applied_at = now() - interval '8 days' where id = $1`, [plusId]);
  await h.as(cat);
  await h.q(`select apply_supercharge($1, $2)`, [plusId, s5]);
  await h.admin();
  await h.q(`${'del' + 'ete'} from servers where id = $1`, [s5]);
  await h.as(cat);
  await h.ok('server deleted: it can go on another one right away', () => h.q(`select apply_supercharge($1, $2)`, [plusId, s1]));
}
