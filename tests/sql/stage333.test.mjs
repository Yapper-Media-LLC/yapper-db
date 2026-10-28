// 333: server verification level (flag server_verification) and the raid alarm (flag raid_alarm).
// Like stage193 this starts from stage 24 (+ flags 031/041) with small stand-ins for the live pieces 333 leans on
// (staff, bots, server_perm with role perms, member_count, webhook column, reaction roles, onboarding answers,
// email_confirmed_at). Then 333 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table auth.users add column if not exists email_confirmed_at timestamptz default now();
alter table public.servers add column if not exists member_count int not null default 0;
alter table public.messages add column if not exists webhook jsonb;
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists auto text not null default 'none';
alter table public.member_roles add column if not exists manual boolean not null default false;
alter table public.app_settings add column if not exists webhook_user_id uuid;
alter table public.app_settings add column if not exists rt_mode text;
alter table public.signup_log add column if not exists user_id uuid;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.bots (id uuid primary key);
create table if not exists public.reaction_roles (message_id uuid, emoji text, role_id uuid, server_id uuid);
create table if not exists public.onboarding_answers (id uuid primary key default gen_random_uuid(), server_id uuid, role_ids uuid[] not null default '{}');
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$$;
create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bots b where b.id = uid);
$$;
create or replace function public.server_perm_user(sid uuid, uid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = uid)
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = uid
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
-- 104's member_roles_mark_manual, verbatim: it rewrites manual on every insert.
create or replace function public.mark_manual_role() returns trigger language plpgsql set search_path = public as $$
begin
  new.manual := exists (
    select 1 from public.roles r join public.server_members m on m.server_id = r.server_id and m.user_id = new.user_id
    where r.id = new.role_id and r.auto = 'before' and (r.auto_before is null or m.joined_at >= r.auto_before));
  return new;
end; $$;
alter table public.roles add column if not exists auto_before timestamptz;
create or replace trigger member_roles_mark_manual before insert on public.member_roles for each row execute function public.mark_manual_role();
-- 155's webhook guard, verbatim: it clears a client-sent webhook field, but only after 333's guard has run.
create or replace function public.message_webhook_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('yapper.webhook', true), '') <> '1' then new.webhook := null; end if;
  else
    new.webhook := old.webhook;
  end if;
  return new;
end $$;
create or replace trigger messages_webhook_insert before insert on public.messages
  for each row when (new.webhook is not null) execute function public.message_webhook_guard();
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select public.server_perm_user(sid, auth.uid(), perm);
$$;
`;

export default async function (h) {
  await h.db.exec(STANDINS);
  const mig = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '333_verification_raid_alarm.sql'), 'utf8');
  await h.db.exec(mig);
  await h.ok('re-runs cleanly', () => h.db.exec(mig));
  h.eq('flags in test mode', (await h.q(`select key, mode from feature_flags where key in ('server_verification', 'raid_alarm') order by key`)),
    [{ key: 'raid_alarm', mode: 'test' }, { key: 'server_verification', mode: 'test' }]);

  const owner = await h.signup('owner@test.dev', 'owner');
  const admin = await h.signup('admin@test.dev', 'admin');
  const kid = await h.signup('kid@test.dev', 'kid');
  const vet = await h.signup('vet@test.dev', 'vet');
  const staff = await h.signup('staff@test.dev', 'staff');
  const bot = await h.signup('bot@test.dev', 'botty');
  const roled = await h.signup('roled@test.dev', 'roled');
  const selfrole = await h.signup('self@test.dev', 'selfrole');
  const raiders = [];
  for (let i = 0; i < 9; i++) raiders.push(await h.signup(`r${i}@raid.shop`, `raider${i}`));

  await h.as(owner);
  const A = (await h.one(`select create_server('Protected', null) id`)).id;
  const B = (await h.one(`select create_server('Open', null) id`)).id;
  await h.admin();
  h.eq('new servers start at Medium', (await h.one(`select verification_level v from servers where id = $1`, [A])).v, 2);
  await h.q(`update servers set verification_level = 0 where id = $1`, [B]);
  await h.q(`update feature_flags set servers = array[$1::uuid, $2::uuid], users = '{}' where key in ('server_verification', 'raid_alarm')`, [A, B]);
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  await h.q(`insert into bots (id) values ($1)`, [bot]);
  const everyone = [admin, kid, vet, staff, bot, roled, selfrole, ...raiders];
  for (const sid of [A, B]) for (const u of everyone) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u]);
  // Old members by default; the test makes some young below.
  await h.q(`update server_members set joined_at = now() - interval '30 days'`);
  const adminRole = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Admin', 9, '{"administrator": true}') returning id`, [A])).id;
  const memberRole = (await h.one(`insert into roles (server_id, name, position) values ($1, 'Regular', 2) returning id`, [A])).id;
  const botRole = (await h.one(`insert into roles (server_id, name, position) values ($1, 'Autorole', 1) returning id`, [A])).id;
  const pickRole = (await h.one(`insert into roles (server_id, name, position) values ($1, 'Pings', 1) returning id`, [A])).id;
  // A bot's autorole: the bot API gives roles with the service key (not 'authenticated'), with manual: true.
  await h.q(`insert into member_roles (server_id, user_id, role_id, manual) values ($1, $2, $3, true)`, [A, kid, botRole]);
  h.eq('a bot-given role isn\'t by_person', (await h.one(`select by_person, manual from member_roles where user_id = $1 and role_id = $2`, [kid, botRole])), { by_person: false, manual: false });
  await h.q(`insert into reaction_roles (server_id, role_id, emoji) values ($1, $2, '🔔')`, [A, pickRole]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3), ($1, $4, $5)`, [A, admin, adminRole, selfrole, pickRole]);

  const chan = async (sid) => (await h.one(`select id from channels where server_id = $1 and kind = 'text' limit 1`, [sid])).id;
  const cA = await chan(A);
  const cB = await chan(B);
  const tryAs = async (uid, sql, params = []) => {
    await h.as(uid);
    try { await h.q(sql, params); return null; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  // The older guards' per-account speed limits aren't under test: age earlier messages.
  const post = async (uid, cid, text = 'hi') => {
    await h.db.exec(`set session_replication_role = replica`);
    await h.q(`update messages set created_at = created_at - interval '1 minute' where author_id = $1`, [uid]);
    await h.db.exec(`set session_replication_role = origin`);
    return tryAs(uid, `insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, uid, text]);
  };
  const age = (uid, mins) => h.q(`update profiles set created_at = now() - make_interval(mins => $2) where id = $1`, [uid, mins]);
  const joinAge = (sid, uid, mins) => h.q(`update server_members set joined_at = now() - make_interval(mins => $3) where server_id = $1 and user_id = $2`, [sid, uid, mins]);
  // Given by the owner (a person): counts. Given by a bot's JWT, or server-side with yapper.bot: doesn't.
  h.eq('owner gives a role', await tryAs(owner, `insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [A, roled, memberRole]), null);
  h.eq('... marked by_person', (await h.one(`select by_person from member_roles where user_id = $1 and role_id = $2`, [roled, memberRole])).by_person, true);

  // ---- Medium: account age ----
  await age(kid, 1);
  const m1 = await post(kid, cA);
  h.eq('1-minute-old account can\'t post in a protected server', m1?.startsWith('This server needs your account to be 5 minutes old before you can talk. Try again in '), true);
  h.eq('... with the wait', /in (4 min|5 min)\.$/.test(m1 ?? ''), true);
  h.eq('... nor react', (await (async () => {
    const mid = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'react to me') returning id`, [cA, vet])).id;
    return tryAs(kid, `insert into reactions (message_id, user_id, emoji) values ($1, $2, '👍')`, [mid, kid]);
  })())?.startsWith('This server needs your account'), true);
  h.eq('same account posts in a level-None server', await post(kid, cB), null);
  await h.db.exec(`set session_replication_role = replica`);
  await h.q(`update messages set created_at = created_at - interval '1 minute' where author_id = $1`, [kid]);
  await h.db.exec(`set session_replication_role = origin`);
  h.eq('a client-sent webhook field doesn\'t skip the check', (await tryAs(kid, `insert into messages (channel_id, author_id, content, webhook) values ($1, $2, 'sneaky', '{"id":"x","name":"x"}')`, [cA, kid]))?.startsWith('This server needs your account'), true);

  // ---- Medium: membership age ----
  await age(kid, 10);
  await joinAge(A, kid, 1);
  const m2 = await post(kid, cA);
  h.eq('10-minute-old account, member for 1 minute: refused', m2?.startsWith('This server needs you to be a member for 5 minutes before you can talk.'), true);
  await joinAge(A, kid, 10);
  h.eq('10-minute-old member can post', await post(kid, cA), null);

  // ---- exemptions ----
  for (const u of [admin, staff, bot, roled, selfrole]) { await age(u, 1); await joinAge(A, u, 1); }
  h.eq('admin (young) posts', await post(admin, cA), null);
  h.eq('staff (young) posts', await post(staff, cA), null);
  h.eq('someone with a real role (young) posts', await post(roled, cA), null);
  h.eq('a role a bot gave (manual) doesn\'t count', (await (async () => { await age(kid, 1); return post(kid, cA); })())?.startsWith('This server needs'), true);
  h.eq('a self-assigned reaction role doesn\'t count', (await post(selfrole, cA))?.startsWith('This server needs'), true);
  h.eq('bot account (young, JWT) can react', await (async () => {
    const mid = (await h.one(`select id from messages where channel_id = $1 order by created_at desc limit 1`, [cA])).id;
    return tryAs(bot, `insert into reactions (message_id, user_id, emoji) values ($1, $2, '🤖')`, [mid, bot]);
  })(), null);
  h.eq('bot post (yapper.bot) passes', await (async () => {
    await h.as(bot);
    try { await h.db.exec(`select set_config('yapper.bot', '1', false)`); await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'beep')`, [cA, bot]); return null; }
    catch (e) { return e.message; }
    finally { await h.db.exec(`select set_config('yapper.bot', '', false)`); await h.admin(); }
  })(), null);
  await age(owner, 1);
  h.eq('owner (young) posts', await post(owner, cA), null);
  await age(owner, 60 * 24 * 30);

  // ---- Low and High ----
  await h.q(`update servers set verification_level = 1 where id = $1`, [A]);
  h.eq('Low: 1-minute-old account refused', (await post(selfrole, cA))?.startsWith('This server needs your account to be 5 minutes old'), true);
  await age(selfrole, 10);
  h.eq('Low: membership age doesn\'t matter', await post(selfrole, cA), null);
  await h.q(`update servers set verification_level = 3 where id = $1`, [A]);
  await joinAge(A, selfrole, 10);
  await h.q(`update auth.users set email_confirmed_at = null where id = $1`, [selfrole]);
  h.eq('High: unverified email refused', (await post(selfrole, cA))?.startsWith('This server needs a verified email'), true);
  await h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [selfrole]);
  h.eq('High: verified email posts', await post(selfrole, cA), null);
  await h.q(`update servers set verification_level = 2 where id = $1`, [A]);

  // ---- flag off: no effect ----
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'server_verification'`, [B]);
  await age(kid, 1);
  h.eq('flag off for A: young account posts', await post(kid, cA), null);
  await h.q(`update feature_flags set servers = array[$1::uuid, $2::uuid] where key = 'server_verification'`, [A, B]);

  // ---- setting it ----
  h.eq('a member can\'t set it', (await tryAs(vet, `select set_verification_level($1, 0)`, [A]))?.includes('Manage Server'), true);
  h.eq('bad level refused', (await tryAs(owner, `select set_verification_level($1, 7)`, [A]))?.includes('Pick'), true);
  h.eq('owner sets None', await tryAs(owner, `select set_verification_level($1, 0)`, [A]), null);
  h.eq('admin sets Medium', await tryAs(admin, `select set_verification_level($1, 2)`, [A]), null);
  await h.q(`update feature_flags set servers = '{}' where key = 'server_verification'`);
  h.eq('flag off: raising refused', (await tryAs(owner, `select set_verification_level($1, 3)`, [A]))?.includes('available'), true);
  h.eq('flag off: lowering fine', await tryAs(owner, `select set_verification_level($1, 1)`, [A]), null);
  await h.q(`update feature_flags set servers = array[$1::uuid, $2::uuid] where key = 'server_verification'`, [A, B]);
  await h.q(`update servers set verification_level = 2 where id = $1`, [A]);
  h.eq('helpers not callable', (await tryAs(kid, `select server_gate($1, $2, true)`, [A, kid])) !== null, true);
  h.eq('raid_fire not callable', (await tryAs(kid, `select raid_fire($1)`, [A])) !== null, true);
  h.eq('raid_hits not readable', (await tryAs(kid, `select * from raid_hits`)) !== null, true);

  // ---- raid alarm: old accounts that just joined (a community moving over) aren't a raid ----
  await h.q(`update server_members set joined_at = now() - interval '10 minutes' where server_id = $1 and user_id = any($2)`, [B, raiders]);
  for (const r of raiders) await age(r, 60 * 24 * 30);
  await h.q(`delete from raid_hits`);
  for (let i = 0; i < 9; i++) await post(raiders[i], cB, 'hello new home');
  h.eq('9 old accounts, new members: no raid', (await h.one(`select raid_until is null x, (select count(*)::int from raid_hits) n from servers where id = $1`, [B])), { x: true, n: 0 });
  await h.q(`update server_members set joined_at = now() - interval '30 days' where server_id = $1`, [B]);

  // ---- raid alarm: a burst of 6-hour-old accounts in the open server ----
  for (const r of raiders) await age(r, 360);
  await age(kid, 60 * 24 * 30);
  await h.q(`delete from raid_hits`); // earlier young posters in B aren't part of this burst
  for (let i = 0; i < 7; i++) h.eq(`raider ${i} posts`, await post(raiders[i], cB, 'spam'), null);
  h.eq('7 new posters: no raid yet', (await h.one(`select raid_until is null x from servers where id = $1`, [B])).x, true);
  h.eq('old member posting doesn\'t count', (await post(vet, cB)) === null && (await h.one(`select count(*)::int n from raid_hits where server_id = $1`, [B])).n, 7);
  h.eq('8th new poster: posts', await post(raiders[7], cB, 'spam'), null);
  const raid = await h.one(`select raid_until > now() + interval '9 minutes' x from servers where id = $1`, [B]);
  h.eq('alarm triggers: raid mode for 10 minutes', raid.x, true);
  const alert = await h.one(`select id, kind, cardinality(user_ids) n, staff from raid_alerts where server_id = $1`, [B]);
  h.eq('alert lists the 8', { kind: alert.kind, n: alert.n, staff: alert.staff }, { kind: 'server', n: 8, staff: false });
  h.eq('raid mode: 9th new account refused', (await post(raiders[8], cB))?.startsWith('This server is in raid mode'), true);
  h.eq('raid mode: old member still posts', await post(vet, cB), null);
  h.eq('raid mode: owner still posts', await post(owner, cB), null);
  h.eq('one alert only', (await h.one(`select count(*)::int n from raid_alerts where server_id = $1`, [B])).n, 1);

  // Who sees it.
  h.eq('a member can\'t read the alert', (await (async () => { await h.as(vet); try { return (await h.q(`select id from raid_alerts`)).length; } finally { await h.admin(); } })()), 0);
  h.eq('the owner can', (await (async () => { await h.as(owner); try { return (await h.q(`select id from raid_alerts`)).length; } finally { await h.admin(); } })()), 1);
  h.eq('staff can', (await (async () => { await h.as(staff); try { return (await h.q(`select id from raid_alerts`)).length; } finally { await h.admin(); } })()), 1);

  // Ban all.
  h.eq('a member can\'t ban all', (await tryAs(vet, `select raid_ban_all($1)`, [alert.id]))?.includes('Ban Members'), true);
  await h.as(owner);
  const banned = (await h.one(`select raid_ban_all($1) n`, [alert.id])).n;
  await h.admin();
  h.eq('owner bans all 8', banned, 8);
  h.eq('... they\'re gone and banned', (await h.one(`select count(*)::int n from server_bans where server_id = $1 and user_id = any($2)`, [B, raiders.slice(0, 8)])).n, 8);
  h.eq('... alert resolved', (await h.one(`select resolved_at is not null x, banned from raid_alerts where id = $1`, [alert.id])), { x: true, banned: 8 });
  h.eq('end raid mode: member refused', (await tryAs(vet, `select end_raid_mode($1)`, [B]))?.includes('can\'t'), true);
  h.eq('end raid mode: owner', await tryAs(owner, `select end_raid_mode($1)`, [B]), null);
  h.eq('raid over: last raider posts', await post(raiders[8], cB), null);

  // Raid alarm flag off: nothing counted.
  await h.q(`update feature_flags set servers = '{}' where key = 'raid_alarm'`);
  await h.q(`delete from raid_hits`);
  h.eq('flag off: posts', await post(raiders[8], cB, 'again'), null);
  h.eq('flag off: no hits counted', (await h.one(`select count(*)::int n from raid_hits`)).n, 0);

  // Threshold scales with size.
  h.eq('threshold small', (await h.one(`select raid_threshold(50) n`)).n, 8);
  h.eq('threshold HQ', (await h.one(`select raid_threshold(80941) n`)).n, 40);
  h.eq('threshold cap', (await h.one(`select raid_threshold(1000000) n`)).n, 50);

  // ---- sign-up bursts ----
  const users = (await h.q(`select id from auth.users where email like '%@raid.shop' order by email`)).map((r) => r.id);
  for (let i = 0; i < 4; i++) await h.q(`insert into signup_log (ip, user_id) values ($1, $2)`, [`10.0.${i}.1`, users[i]]);
  h.eq('4 on one domain: no alert', (await h.one(`select count(*)::int n from raid_alerts where kind = 'signup_domain'`)).n, 0);
  await h.q(`insert into signup_log (ip, user_id) values ('10.0.9.1', $1)`, [users[4]]);
  h.eq('5th on one domain: staff alert', await h.one(`select key, cardinality(user_ids) n, staff from raid_alerts where kind = 'signup_domain'`), { key: 'raid.shop', n: 5, staff: true });
  await h.q(`insert into signup_log (ip, user_id) values ('10.0.9.2', $1)`, [users[5]]);
  h.eq('6th joins the same alert', (await h.one(`select count(*)::int c, max(cardinality(user_ids)) n from raid_alerts where kind = 'signup_domain'`)), { c: 1, n: 6 });
  for (let i = 0; i < 6; i++) await h.q(`insert into signup_log (ip, user_id) values ($1, $2)`, [`172.16.4.${i + 10}`, everyone[i]]);
  h.eq('6 from one /24: staff alert', await h.one(`select key, cardinality(user_ids) n from raid_alerts where kind = 'signup_ip'`), { key: '172.16.4.', n: 6 });
  const gm = [];
  for (let i = 0; i < 6; i++) gm.push(await h.signup(`g${i}@gmail.com`, `gmailer${i}`));
  for (let i = 0; i < 6; i++) await h.q(`insert into signup_log (ip, user_id) values ($1, $2)`, [`192.168.${i}.1`, gm[i]]);
  h.eq('big mail providers are never flagged', (await h.one(`select count(*)::int n from raid_alerts where key = 'gmail.com'`)).n, 0);
  h.eq('a sign-up with no usable IP is fine', await (async () => { try { await h.q(`insert into signup_log (ip, user_id) values ('unknown', $1)`, [users[6]]); return null; } catch (e) { return e.message; } })(), null);

  // Staff marking a sign-up alert done.
  const sAlert = (await h.one(`select id from raid_alerts where kind = 'signup_domain'`)).id;
  h.eq('a member can\'t dismiss it', (await tryAs(vet, `select raid_alert_done($1, 0)`, [sAlert]))?.includes('can\'t'), true);
  h.eq('staff dismisses it', await tryAs(staff, `select raid_alert_done($1, 6)`, [sAlert]), null);
}
