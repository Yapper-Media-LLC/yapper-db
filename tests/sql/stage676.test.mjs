// 676: Yapin' Partner servers. partner_check (every requirement), partner_eligibility (owner/staff, flag), partner_apply
// (owner, all checks, one pending, 30-day wait after a no), partner_review (admins + Management, not your own server,
// badge only when they didn't have it, mod_log), partner_revoke (badge back only when we gave it), the owner-move trigger,
// partner_recheck (flags after 30 days below, never revokes), decision notices, partner_ids, invite_card, no table access.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');
const TEST_SERVER = '00000000-0000-4000-8000-00000000b001';
const ANTIC = '00000000-0000-4000-8000-00000000a001';

export default async function (h) {
  await h.admin();
  // Stand-ins for what 676 reads from migrations past the PGlite base.
  await h.db.exec(`
    create table if not exists public.manager_standin (user_id uuid primary key);
    create table if not exists public.banned_standin (user_id uuid primary key);
    create table if not exists public.level_standin (server_id uuid primary key, lvl int not null);
    create table if not exists public.notice_standin (topic text, event text, payload jsonb);
    create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
      target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
    create or replace function public.is_site_manager() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.manager_standin where user_id = auth.uid()) $$;
    create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.banned_standin where user_id = uid) $$;
    create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable as $$ select false $$;
    create or replace function public.server_level(sid uuid) returns int language sql stable security definer set search_path = public
      as $$ select coalesce((select lvl from public.level_standin where server_id = sid), 0) $$;
    create or replace function public.rt_profile_changed(uids uuid[]) returns void language sql as $$ select $$;
    create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language sql
      security definer set search_path = public as $$ insert into public.notice_standin values (topic_name, event_name, payload) $$;
    create or replace function public.presence_ttl() returns interval language sql immutable as $$ select interval '2 minutes' $$;
    create table if not exists public.presence (user_id uuid primary key, last_seen timestamptz);
    alter table public.profiles add column if not exists badges text[] not null default '{}';
    alter table public.profiles add column if not exists shown_badge text;
    alter table public.reports add column if not exists reported_server_id uuid references public.servers (id) on delete set null;
    alter table public.servers add column if not exists member_count int not null default 0;
    alter table public.servers add column if not exists rules_channel_id uuid;
    alter table public.servers add column if not exists verification_level smallint not null default 2;
    alter table public.servers add column if not exists name_ok boolean not null default true;
    alter table public.servers add column if not exists staff_hidden_at timestamptz;
    alter table public.servers add column if not exists staff_warned_at timestamptz;
    alter table public.servers add column if not exists shut_down_at timestamptz;
    alter table public.servers add column if not exists banner_path text;
    alter table public.servers add column if not exists banner_x real;
    alter table public.servers add column if not exists banner_y real;
    alter table public.servers add column if not exists banner_zoom real;
    create table if not exists public.server_onboarding (server_id uuid primary key, enabled boolean not null default false);
    create table if not exists public.server_audit_log (id bigint generated always as identity primary key, server_id uuid not null,
      actor_id uuid, action text not null, target_id uuid, created_at timestamptz not null default now());
  `);
  await h.db.exec(mig('676_partner_servers.sql'));
  await h.ok('676 re-runs cleanly', () => h.db.exec(mig('676_partner_servers.sql')));
  h.eq('flag row in test for Antic and the HQ test server', (await h.q(`select mode, servers, users from feature_flags where key = 'partner_servers'`))[0],
    { mode: 'test', servers: [TEST_SERVER], users: [ANTIC] });
  h.eq('no MCP-hanging words', /\b(drop|truncate)\b|delete from/i.test(mig('676_partner_servers.sql')), false);

  const owner = await h.signup('own@test.dev', 'owner');
  const mod1 = await h.signup('m1@test.dev', 'mod1');
  const mod2 = await h.signup('m2@test.dev', 'mod2');
  const admin = await h.signup('admin@test.dev', 'admin');
  const manager = await h.signup('mgr@test.dev', 'manager');
  const user = await h.signup('u@test.dev', 'user');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '100 days'`);
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into manager_standin values ($1)`, [manager]);
  // Admin + manager are listed flag users so feature_on_for_me is on for them.
  await h.q(`update feature_flags set users = users || $1::uuid || $2::uuid where key = 'partner_servers'`, [admin, manager]);
  await h.q(`insert into servers (id, name, owner_id, member_count, created_at) values ($1, 'HQ test', $2, 1500, now() - interval '70 days')`, [TEST_SERVER, owner]);
  const other = (await h.q(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner]))[0].id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4) on conflict do nothing`, [TEST_SERVER, mod1, mod2, user]);
  await h.q(`insert into invites (code, server_id, created_by) values ('PARTNR', $1, $2)`, [TEST_SERVER, owner]);

  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const elig = (who, sid = TEST_SERVER) => call(who, `select partner_eligibility($1)`, [sid]);
  const failing = (e) => e.checks.filter((c) => !c.ok).map((c) => c.key);
  const apply = (who, sid = TEST_SERVER, about = 'A big friendly gaming server with weekly events.', links = ['https://yapper.website']) =>
    call(who, `select partner_apply($1, $2, $3)`, [sid, about, links]);
  const isId = (v) => /^[0-9a-f-]{36}$/.test(String(v));

  // ---- eligibility ----
  h.eq('flag off for this server: refused', await elig(owner, other), 'Not available yet');
  h.eq('not the owner: refused', await elig(user), 'Only the owner can do that');
  let e = await elig(owner);
  h.eq('fresh: level, rules, mods fail', failing(e), ['level', 'rules', 'mods']);
  h.eq('values come back', e.checks.find((c) => c.key === 'members').value, 1500);
  h.eq('staff can read it too', typeof (await elig(admin)).ok, 'boolean');

  await h.q(`insert into level_standin values ($1, 2)`, [TEST_SERVER]);
  await h.q(`insert into server_onboarding values ($1, true)`, [TEST_SERVER]);
  await h.q(`insert into server_audit_log (server_id, actor_id, action) values ($1, $2, 'member_ban'), ($1, $3, 'member_kick'), ($1, $4, 'member_kick'), ($1, $3, 'member_timeout'),
    ($1, $5, 'invite_create'), ($1, $5, 'channel_create')`, [TEST_SERVER, owner, mod1, mod2, user]);
  await h.q(`insert into server_audit_log (server_id, actor_id, action, target_id) values ($1, $2, 'voice_mute', $2)`, [TEST_SERVER, user]);
  h.eq('owner, invites, channel edits and self-mutes do not count as mods', (await elig(owner)).checks.find((c) => c.key === 'mods').value, 2);
  await h.q(`update server_audit_log set created_at = now() - interval '40 days' where actor_id = $1`, [mod2]);
  h.eq('old mod actions do not count', (await elig(owner)).checks.find((c) => c.key === 'mods').value, 1);
  await h.q(`update server_audit_log set created_at = now() where actor_id = $1`, [mod2]);
  h.eq('rules from onboarding', (await elig(owner)).checks.find((c) => c.key === 'rules').value, 'Onboarding');
  await h.q(`update servers set verification_level = 1 where id = $1`, [TEST_SERVER]);
  h.eq('low verification fails safety', failing(await elig(owner)), ['safety']);
  await h.q(`update servers set verification_level = 2, created_at = now() - interval '20 days' where id = $1`, [TEST_SERVER]);
  h.eq('young server fails age', failing(await elig(owner)), ['age']);
  await h.q(`update servers set created_at = now() - interval '70 days' where id = $1`, [TEST_SERVER]);
  await h.q(`insert into reports (reporter_id, reason, reported_server_id) values ($1, 'spam', $2)`, [user, TEST_SERVER]);
  e = await elig(owner);
  h.eq('open report fails clean', [failing(e), e.checks.find((c) => c.key === 'clean').value], [['clean'], '1 open report']);
  await h.q(`update reports set status = 'dismissed' where reported_server_id = $1`, [TEST_SERVER]);
  h.eq('all pass', (await elig(owner)).ok, true);

  // ---- apply ----
  h.eq('not the owner cannot apply', await apply(user), 'Only the owner can do that');
  h.eq('too short', await apply(owner, TEST_SERVER, 'hi'), 'Tell us a bit more about your server');
  h.eq('bad link', await apply(owner, TEST_SERVER, undefined, ['javascript:alert(1)']), 'Links need to start with https://');
  await h.q(`update level_standin set lvl = 1`);
  h.eq('must pass everything', await apply(owner), 'Your server doesn\'t meet every requirement yet');
  await h.q(`update level_standin set lvl = 3`);
  const a1 = await apply(owner);
  h.eq('owner applies', isId(a1), true);
  h.eq('only one pending', await apply(owner), 'You already applied. Staff will take a look.');
  h.eq('application shows on the page', (await elig(owner)).application.status, 'pending');

  // ---- no direct table access ----
  h.eq('owner cannot read the table', await call(owner, `select count(*) from partner_applications`), 'permission denied for table partner_applications');
  h.eq('owner cannot set partner_since', String(await call(owner, `update servers set partner_since = now() where id = $1`, [TEST_SERVER])).includes('permission denied') ||
    (await h.one(`select partner_since from servers where id = $1`, [TEST_SERVER])).partner_since === null, true);
  h.eq('nobody calls the check directly', await call(owner, `select partner_check($1)`, [TEST_SERVER]), 'permission denied for function partner_check');
  h.eq('nobody runs the recheck', await call(admin, `select partner_recheck()`), 'permission denied for function partner_recheck');

  // ---- queue + review ----
  h.eq('mods/users cannot see the queue', await call(user, `select partner_queue()`), 'Staff only');
  const qd = await call(manager, `select partner_queue()`);
  h.eq('manager sees the pending one with live checks', [qd.apps.length, qd.apps[0].now.ok, qd.apps[0].owner], [1, true, 'owner']);
  h.eq('user cannot review', await call(user, `select partner_review($1, true, '')`, [a1]), 'Staff only');
  h.eq('deny needs a reason', await call(admin, `select partner_review($1, false, '')`, [a1]), 'Add a short reason, they see it');
  await h.q(`update profiles set badges = '{bug_hunter}' where id = $1`, [owner]);
  h.eq('admin approves', await call(admin, `select partner_review($1, true, 'Welcome!')`, [a1]), 'ok');
  h.eq('server marked, badge given', [(await h.one(`select partner_since is not null p from servers where id = $1`, [TEST_SERVER])).p,
    (await h.one(`select badges from profiles where id = $1`, [owner])).badges], [true, ['bug_hunter', 'partner']]);
  h.eq('logged', (await h.q(`select action from mod_log where target_id = $1 order by created_at, action`, [owner])).map((r) => r.action).sort(),
    ['badge_given', 'partner_approved']);
  h.eq('owner notified live', (await h.one(`select topic, event, payload->>'status' s from notice_standin`)), { topic: 'user:' + owner, event: 'partner_application', s: 'approved' });
  h.eq('second decision refused', await call(manager, `select partner_review($1, false, 'nope')`, [a1]), 'Someone already decided on this one');
  h.eq('already a partner', await apply(owner), 'This server is already a partner');
  const dec = await call(owner, `select my_partner_decisions()`);
  h.eq('decision notice waits', [dec.length, dec[0].status], [1, 'approved']);
  await call(owner, `select ack_partner_decision($1)`, [a1]);
  h.eq('dismissed', (await call(owner, `select my_partner_decisions()`)).length, 0);
  h.eq('partner_ids for anyone', await call(null, `select partner_ids($1)`, [[TEST_SERVER, other]]), [TEST_SERVER]);
  h.eq('invite card says partner', (await call(null, `select invite_card('partnr')`)).partner, true);

  // ---- recheck: flag after 30 days, never revoke ----
  await h.q(`update level_standin set lvl = 1`);
  h.eq('first fail: not flagged yet', await h.one(`select partner_recheck() n`), { n: 0 });
  h.eq('watch row', (await h.one(`select failing, flagged_at from partner_watch where server_id = $1`, [TEST_SERVER])), { failing: ['level'], flagged_at: null });
  await h.q(`update partner_watch set below_since = now() - interval '31 days'`);
  h.eq('31 days below: flagged', await h.one(`select partner_recheck() n`), { n: 1 });
  h.eq('still a partner', (await h.one(`select partner_since is not null p from servers where id = $1`, [TEST_SERVER])).p, true);
  h.eq('flagged in the queue', (await call(admin, `select partner_queue()`)).flagged.map((f) => f.failing), [['level']]);
  h.eq('keep restarts the clock', await call(admin, `select partner_keep($1)`, [TEST_SERVER]), 'ok');
  h.eq('no longer flagged', (await call(admin, `select partner_queue()`)).flagged.length, 0);
  await h.q(`update level_standin set lvl = 3`);
  await h.q(`select partner_recheck()`);
  h.eq('passing again clears the watch', (await h.one(`select below_since from partner_watch where server_id = $1`, [TEST_SERVER])).below_since, null);

  // ---- owner moves: the badge moves ----
  await h.q(`update servers set owner_id = $1 where id = $2`, [mod1, TEST_SERVER]);
  h.eq('old owner loses it, new owner gets it', [(await h.one(`select badges from profiles where id = $1`, [owner])).badges,
    (await h.one(`select badges from profiles where id = $1`, [mod1])).badges], [['bug_hunter'], ['partner']]);

  // ---- revoke ----
  h.eq('revoke needs a reason', await call(admin, `select partner_revoke($1, '')`, [TEST_SERVER]), 'Add a short reason, they see it');
  h.eq('revoke', await call(admin, `select partner_revoke($1, 'Inactive mods')`, [TEST_SERVER]), 'ok');
  h.eq('unmarked, badge back off', [(await h.one(`select partner_since from servers where id = $1`, [TEST_SERVER])).partner_since,
    (await h.one(`select badges from profiles where id = $1`, [mod1])).badges], [null, []]);
  h.eq('30-day wait after a revoke', await call(mod1, `select partner_apply($1, $2, '{}')`, [TEST_SERVER, 'A big friendly gaming server with weekly events.']),
    'You can apply again 30 days after the last decision');

  // A badge they already had (given by hand) stays when partner status goes.
  await h.q(`update profiles set badges = '{partner}' where id = $1`, [mod1]);
  await h.q(`update partner_applications set reviewed_at = now() - interval '31 days'`);
  // mod1 owns it now, so their own actions stop counting: someone else steps up.
  await h.q(`insert into server_audit_log (server_id, actor_id, action) values ($1, $2, 'member_kick')`, [TEST_SERVER, user]);
  const a2 = await call(mod1, `select partner_apply($1, $2, '{}')`, [TEST_SERVER, 'A big friendly gaming server with weekly events.']);
  h.eq('applies again after the wait', isId(a2), true);
  h.eq('cannot review your own server', await call(mod1, `select partner_review($1, true, '')`, [a2]), 'Staff only');
  await h.q(`insert into manager_standin values ($1)`, [mod1]);
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'partner_servers'`, [mod1]);
  h.eq('a manager cannot review their own server', await call(mod1, `select partner_review($1, true, '')`, [a2]), 'You can\'t review your own server');
  await call(manager, `select partner_review($1, true, '')`, [a2]);
  await call(manager, `select partner_revoke($1, 'testing')`, [TEST_SERVER]);
  h.eq('hand-given badge stays', (await h.one(`select badges from profiles where id = $1`, [mod1])).badges, ['partner']);

  // Given by the program, then also by hand (admin_set_badge logs reason 'partner'): a revoke leaves it.
  const own2 = await h.signup('own2@test.dev', 'owner2');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '100 days' where id = $1`, [own2]);
  await h.q(`update servers set owner_id = $1 where id = $2`, [own2, TEST_SERVER]);
  await h.q(`update partner_applications set reviewed_at = now() - interval '31 days'`);
  const a3 = await call(own2, `select partner_apply($1, $2, '{}')`, [TEST_SERVER, 'A big friendly gaming server with weekly events.']);
  await call(admin, `select partner_review($1, true, '')`, [a3]);
  h.eq('program gave it', (await h.one(`select gave_badge from partner_applications where id = $1`, [a3])).gave_badge, true);
  await h.q(`insert into mod_log (actor, action, target_id, reason) values ($1, 'badge_given', $2, 'partner')`, [admin, own2]);
  await call(admin, `select partner_revoke($1, 'testing')`, [TEST_SERVER]);
  h.eq('badge given by hand too: kept', (await h.one(`select badges from profiles where id = $1`, [own2])).badges, ['partner']);

  // Deleting a partner server takes the badge back.
  const own3 = await h.signup('own3@test.dev', 'owner3');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '100 days' where id = $1`, [own3]);
  await h.q(`update servers set owner_id = $1 where id = $2`, [own3, TEST_SERVER]);
  await h.q(`update partner_applications set reviewed_at = now() - interval '31 days'`);
  const a4 = await call(own3, `select partner_apply($1, $2, '{}')`, [TEST_SERVER, 'A big friendly gaming server with weekly events.']);
  await call(admin, `select partner_review($1, true, '')`, [a4]);
  h.eq('owner3 has it', (await h.one(`select badges from profiles where id = $1`, [own3])).badges, ['partner']);
  await h.q(`delete from servers where id = $1`, [TEST_SERVER]);
  h.eq('server deleted: badge gone', (await h.one(`select badges from profiles where id = $1`, [own3])).badges, []);
}
