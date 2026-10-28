// 304 alt guard: device/network memory, evasion_check, device bans, sign-ups only through the route, first-day limits.
// PGlite stops at 24, so this adds stand-ins for what the migration touches (live versions of these are bigger).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '304_alt_guard.sql'), 'utf8');

// The live standing_guard text (minus the parts the patch doesn't touch it would be the same).
const STANDING = `
create or replace function public.standing_guard(action text, sid uuid default null, other uuid default null)
returns void language plpgsql stable security definer set search_path to 'public' as $function$
declare me uuid := auth.uid(); tier text; why text;
begin
  if me is null then return; end if;
  if not public.feature_on('account_standing', sid) then return; end if;
  if public.is_staff() then return; end if;
  return;
end $function$;`;

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.profiles add column if not exists badges text[];
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.feature_flags f where f.key = k and (f.mode = 'everyone' or (f.mode = 'test' and (auth.uid() = any(f.users) or sid = any(f.servers))))) $$;
create or replace function public.is_staff() returns boolean language sql stable as $$ select public.is_site_admin() $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())) $$;
create table if not exists public.pending_bot_emails (email text primary key, created_at timestamptz not null default now());
create table if not exists public.signup_log (id bigserial primary key, ip text, created_at timestamptz default now());
create or replace function public.ip_banned_recently(p_ip text) returns boolean language sql stable as $$ select p_ip = '9.9.9.9' $$;
${STANDING}
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('304 re-runs cleanly', () => h.db.exec(MIG));
  const MARK = 'First day (flag new_account_limits';
  h.eq('standing_guard was patched once', (await h.one(`select (length(pg_get_functiondef('public.standing_guard(text,uuid,uuid)'::regprocedure))
    - length(replace(pg_get_functiondef('public.standing_guard(text,uuid,uuid)'::regprocedure), $1, ''))) / length($1) n`, [MARK])).n, 1);

  const admin = await h.signup('admin303@test.dev', 'admin303');
  const bad = await h.signup('bad303@test.dev', 'bad303');
  const other = await h.signup('other303@test.dev', 'other303');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1) on conflict do nothing`, [admin]);
  // bad303 is an old account; everyone else here is made after its ban.
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [bad]);
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [other]);

  const DEV = 'dev_aaaaaaaaaaaaaaaaaaaa';
  const setIp = async (ip) => h.q(`select set_config('request.headers', $1, false)`, [JSON.stringify({ 'cf-connecting-ip': ip, 'x-forwarded-for': `6.6.6.6, ${ip}` })]);

  // ---- note_device remembers hashes, nobody can read them ----
  await h.as(bad);
  await setIp('1.2.3.4');
  await h.ok('a user notes their device', () => h.q(`select note_device($1)`, [DEV]));
  await h.admin();
  h.eq('device and network rows, hashed', (await h.one(`select count(*)::int n, bool_and(h ~ '^[0-9a-f]{64}$') hashed from user_devices where user_id = $1`, [bad])), { n: 2, hashed: true });
  h.eq('the raw device id is not stored', (await h.one(`select count(*)::int n from user_devices where h = $1`, [DEV])).n, 0);
  await h.as(bad);
  await h.fails('users cannot read user_devices', `select * from user_devices`);
  await h.as(null);
  await h.fails('anon cannot note a device', `select note_device($1)`, [DEV]);
  await h.as(bad);
  await h.fails('users cannot call evasion_check', `select evasion_check('1.2.3.4', $1)`, [DEV]);
  await h.ok('a junk device id is ignored', () => h.q(`select note_device('x')`));
  await h.admin();
  h.eq('only the Cloudflare address is stored, not the spoofable x-forwarded-for', (await h.one(`select count(*)::int n from user_devices where kind = 'ip' and h = evasion_hash('6.6.6.6')`)).n, 0);
  // At most 5 new devices a day per account.
  await h.as(other);
  for (let i = 0; i < 8; i++) await h.q(`select note_device($1)`, [`dev_spam${i}xxxxxxxxxxxxxxxx`]);
  await h.admin();
  h.eq('device spam is capped at 5 a day', (await h.one(`select count(*)::int n from user_devices where user_id = $1 and kind = 'dev'`, [other])).n, 5);
  await h.q(`delete from user_devices where user_id = $1`, [other]);
  h.eq('IPv6 counts as its /64', (await h.one(`select ip_key('2001:db8:1:2:aaaa:bbbb:cccc:dddd') = ip_key('2001:db8:1:2:1111:2222:3333:4444') same`)).same, true);

  // ---- not banned yet: nothing matches ----
  await h.admin();
  h.eq('no ban, no match', (await h.one(`select evasion_check('1.2.3.4', $1) k`, [DEV])).k, null);

  await h.q(`insert into site_bans (user_id, reason, banned_by, created_at) values ($1, 'test', $2, now() - interval '1 day')`, [bad, admin]);
  h.eq('a banned device is refused', (await h.one(`select evasion_check('5.5.5.5', $1) k`, [DEV])).k, 'device');
  h.eq('a banned network is refused', (await h.one(`select evasion_check('1.2.3.4', 'dev_bbbbbbbbbbbbbbbbbbbb') k`)).k, 'network');
  h.eq('a fresh device on a fresh network is fine', (await h.one(`select evasion_check('5.5.5.5', 'dev_bbbbbbbbbbbbbbbbbbbb') k`)).k, null);
  h.eq('the old network check still counts', (await h.one(`select evasion_check('9.9.9.9', null) k`)).k, 'network');

  // A network shared by more than 30 accounts doesn't count.
  for (let i = 0; i < 31; i++) {
    const u = await h.signup(`crowd${i}@test.dev`, `crowd303_${i}`);
    await h.admin();
    await h.q(`insert into user_devices (user_id, kind, h) values ($1, 'ip', evasion_hash('1.2.3.4'))`, [u]);
  }
  h.eq('a crowded network (school, carrier) is not refused', (await h.one(`select evasion_check('1.2.3.4', 'dev_bbbbbbbbbbbbbbbbbbbb') k`)).k, null);

  // ---- device bans ----
  h.eq('device bans start in test', (await h.one(`select mode from feature_flags where key = 'device_bans'`)).mode, 'test');
  await h.q(`update feature_flags set mode = 'everyone' where key = 'device_bans'`);
  const alt = await h.signup('alt303@test.dev', 'alt303');
  await h.as(alt);
  await setIp('7.7.7.7');
  h.eq('an alt made after the ban, on that device, is banned when it shows up', (await h.one(`select note_device($1) r`, [DEV])).r, 'banned');
  await h.admin();
  h.eq('...with a site ban', (await h.one(`select count(*)::int n from site_bans where user_id = $1`, [alt])).n, 1);
  h.eq('...logged as ban evasion', (await h.one(`select reason from mod_log where action = 'ban_evasion' and target_id = $1`, [alt])).reason, 'Same device as bad303');
  await h.as(other);
  h.eq('an account older than the ban on the same device is left alone', (await h.one(`select note_device($1) r`, [DEV])).r, null);
  await h.admin();
  h.eq('...not banned', (await h.one(`select count(*)::int n from site_bans where user_id = $1`, [other])).n, 0);
  await h.q(`update feature_flags set mode = 'off' where key = 'device_bans'`);
  const alt2 = await h.signup('alt2303@test.dev', 'alt2303');
  await h.as(alt2);
  h.eq('with the flag off, nobody is banned', (await h.one(`select note_device($1) r`, [DEV])).r, null);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'device_bans'`);
  // The auto-banned alt is on that device too, so its ban counts as well: end both.
  await h.q(`update site_bans set expires_at = now() - interval '1 minute' where user_id = any($1)`, [[bad, alt]]);
  const alt3 = await h.signup('alt3303@test.dev', 'alt3303');
  await h.as(alt3);
  h.eq('an ended ban no longer follows the device', (await h.one(`select note_device($1) r`, [DEV])).r, null);
  await h.admin();

  // ---- sign-ups only through the route ----
  await h.ok('flag off: a direct sign-up still works', () => h.signup('direct1@test.dev', 'direct1'));
  await h.q(`update feature_flags set mode = 'everyone' where key = 'signup_route_only'`);
  await h.fails('flag on: a direct sign-up is refused', `insert into auth.users (email) values ('direct2@test.dev')`);
  await h.q(`insert into pending_signups (email) values ('route@test.dev')`);
  await h.ok('one noted by the route goes through (any case)', () => h.q(`insert into auth.users (email) values ('Route@test.dev')`));
  h.eq('...and the note is used up', (await h.one(`select count(*)::int n from pending_signups where email = 'route@test.dev'`)).n, 0);
  await h.q(`insert into pending_bot_emails (email) values ('bot-1@bots.yapper.website')`);
  await h.ok('our own bot accounts go through', () => h.q(`insert into auth.users (email) values ('bot-1@bots.yapper.website')`));
  await h.q(`insert into pending_signups (email, created_at) values ('old@test.dev', now() - interval '5 minutes')`);
  await h.fails('an old note does not count', `insert into auth.users (email) values ('old@test.dev')`);
  await h.q(`update feature_flags set mode = 'off' where key = 'signup_route_only'`);

  // ---- first-day limits ----
  const fresh = await h.signup('fresh303@test.dev', 'fresh303');
  await h.admin();
  const guard = async (who, action, oth) => { await h.as(who); try { await h.q(`select standing_guard($1, null, $2)`, [action, oth]); return 'ok'; } catch (e) { return e.message; } finally { await h.admin(); } };
  h.eq('flag in test: a fresh account still posts links', await guard(fresh, 'link', null), 'ok');
  await h.q(`update feature_flags set mode = 'everyone' where key = 'new_account_limits'`);
  h.eq('a fresh account cannot post links', await guard(fresh, 'link', null), 'New accounts can post links after their first day.');
  h.eq('...cannot DM a stranger', await guard(fresh, 'dm_open', other), 'New accounts can only DM friends on their first day.');
  await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted')`, [fresh, other]);
  h.eq('...can DM a friend', await guard(fresh, 'dm_open', other), 'ok');
  for (let i = 0; i < 4; i++) {
    const t = await h.signup(`target${i}@test.dev`, `target303_${i}`);
    await h.admin();
    await h.q(`insert into friendships (requester, addressee) values ($1, $2)`, [fresh, t]);
  }
  h.eq('...4 sent today (plus 1 accepted) = 5: the next is refused', await guard(fresh, 'friend', null), 'New accounts can send 5 friend requests on their first day.');
  h.eq('an older account is not limited', await guard(other, 'link', null), 'ok');
  h.eq('staff are not limited', await guard(admin, 'link', null), 'ok');
  await h.q(`update profiles set badges = '{bot}' where id = $1`, [fresh]);
  h.eq('bots are not limited', await guard(fresh, 'link', null), 'ok');

  // ---- grants ----
  const can = async (role, fn) => (await h.one(`select has_function_privilege($1, $2, 'execute') r`, [role, fn])).r;
  h.eq('anon cannot run note_device', await can('anon', 'public.note_device(text)'), false);
  h.eq('signed-in can run note_device', await can('authenticated', 'public.note_device(text)'), true);
  for (const fn of ['public.evasion_check(text, text)', 'public.evasion_match(text, text)', 'public.evasion_hash(text)', 'public.request_ip()', 'public.ip_key(text)']) {
    h.eq(`signed-in cannot run ${fn}`, await can('authenticated', fn), false);
    h.eq(`anon cannot run ${fn}`, await can('anon', fn), false);
  }
  await h.as(bad);
  await h.fails('users cannot read the salt', `select * from evasion_salt`);
  await h.admin();
  h.eq('signup_log has user_id', (await h.one(`select count(*)::int n from information_schema.columns where table_name = 'signup_log' and column_name = 'user_id'`)).n, 1);
}
