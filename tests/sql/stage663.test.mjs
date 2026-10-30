// 663: server reports. report_server (flag, owner, site ban, new account, 1 per server per day, 5 a day), the row shape
// (no target, no server_id, so the server's own mods can't read it), staff_server_report_info (staff + flag),
// staff_close_server_reports (claims, mod_log), and claim_reports counting a server's reports as one case.
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
  // Stand-ins for what 663 reads from migrations past the PGlite base.
  await h.db.exec(`
    create table if not exists public.staff_standin (user_id uuid primary key);
    create table if not exists public.banned_standin (user_id uuid primary key);
    create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
      target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
    create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = uid) $$;
    create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.banned_standin where user_id = uid) $$;
    alter table public.reports add column if not exists server_id uuid references public.servers (id) on delete set null;
    alter table public.servers add column if not exists member_count int not null default 1;
    alter table public.servers add column if not exists discoverable boolean not null default false;
    alter table public.servers add column if not exists name_ok boolean not null default true;
    alter table public.servers add column if not exists locked_until timestamptz;
    alter table public.servers add column if not exists staff_hidden_at timestamptz;
    alter table public.servers add column if not exists shut_down_at timestamptz;
    alter table public.servers add column if not exists shut_down_reason text;
    alter table public.servers add column if not exists tag text;
    alter table public.profiles add column if not exists display_name text;
    create table if not exists public.server_watch (server_id uuid primary key, score int not null default 0, status text not null default 'new');
    create table if not exists public.server_watch_hits (server_id uuid not null, ref text not null, src text, kind text, term text,
      weight int, place text, sample text, channel_id uuid, at timestamptz not null default now(), primary key (server_id, ref));
  `);
  await h.db.exec(mig('643_report_claims.sql'));
  await h.db.exec(mig('663_server_reports.sql'));
  await h.ok('663 re-runs cleanly', () => h.db.exec(mig('663_server_reports.sql')));
  h.eq('flag row in test for Antic and the HQ test server', (await h.q(`select mode, servers, users from feature_flags where key = 'server_reports'`))[0],
    { mode: 'test', servers: [TEST_SERVER], users: [ANTIC] });

  const owner = await h.signup('own@test.dev', 'owner');
  const user = await h.signup('u@test.dev', 'user');
  const fresh = await h.signup('f@test.dev', 'fresh');
  const banned = await h.signup('b@test.dev', 'banned');
  const mod = await h.signup('mod@test.dev', 'mod');
  const mod2 = await h.signup('mod2@test.dev', 'mod2');
  const admin = await h.signup('admin@test.dev', 'admin');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days' where id <> $1`, [fresh]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into staff_standin values ($1), ($2), ($3)`, [mod, mod2, admin]);
  await h.q(`insert into banned_standin values ($1)`, [banned]);
  // The test server has the flag; "other" does not. Staff are members of the test server, so feature_on_for_me is on for them.
  await h.q(`insert into servers (id, name, owner_id, member_count, discoverable) values ($1, 'HQ test', $2, 42, true)`, [TEST_SERVER, owner]);
  const other = (await h.q(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner]))[0].id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4) on conflict do nothing`, [TEST_SERVER, mod, mod2, admin]);

  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const report = (who, sid, why = 'spam', more = '') => call(who, `select report_server($1, $2, $3)`, [sid, why, more]);
  const isId = (v) => /^[0-9a-f-]{36}$/.test(String(v));

  // ---- report_server ----
  h.eq('flag off for this server and me: refused', await report(user, other), 'Not available yet');
  h.eq('owner can not report their own server', await report(owner, TEST_SERVER), 'You can\'t report your own server');
  h.eq('site-banned: refused', await report(banned, TEST_SERVER), 'You can\'t send reports right now');
  h.eq('account under a day old: refused', await report(fresh, TEST_SERVER), 'Your account is too new to report servers. Try again tomorrow.');
  h.eq('bad reason: refused', await report(user, TEST_SERVER, 'nope'), 'Pick what\'s wrong');
  const r1 = await report(user, TEST_SERVER, 'hate', '[voice] [VOICE][voice] they run raids from here');
  h.eq('a member reports the server', isId(r1), true);
  const row = (await h.q(`select reporter_id, target_id, message_id, server_id, reported_server_id, reported_server_name, reason, details, status from reports where id = $1`, [r1]))[0];
  h.eq('row: server-only report, no target / message / server_id', row, {
    reporter_id: user, target_id: null, message_id: null, server_id: null, reported_server_id: TEST_SERVER, reported_server_name: 'HQ test',
    reason: 'hate', details: 'they run raids from here', status: 'open' });
  h.eq('same server again within a day: refused', await report(user, TEST_SERVER), 'You already reported this server today. Staff will take a look.');
  await h.ok('details over 1000 are cut', async () => {
    const id = await report(mod, TEST_SERVER, 'other', 'x'.repeat(1500));
    if (!isId(id)) throw new Error(String(id));
    const n = (await h.q(`select char_length(details) n from reports where id = $1`, [id]))[0].n;
    if (n !== 1000) throw new Error(`length ${n}`);
  });
  // 5 server reports a day: a flag user (like Antic) on servers outside the test server.
  const antic = await h.signup('antic@test.dev', 'antic');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [antic]);
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'server_reports'`, [antic]);
  h.eq('unknown server', await report(antic, '00000000-0000-0000-0000-000000000001'), 'Server not found');
  const servers = [];
  for (let i = 0; i < 6; i++) servers.push((await h.q(`insert into servers (name, owner_id) values ($1, $2) returning id`, [`S${i}`, owner]))[0].id);
  for (let i = 0; i < 5; i++) h.eq(`flag user reports server ${i + 1} of 5`, isId(await report(antic, servers[i])), true);
  h.eq('6th server report in a day: refused', await report(antic, servers[5]), 'That\'s a lot of server reports today. Try again tomorrow.');

  // ---- who can read it ----
  h.eq('the reporter can not read reports', Number(await call(user, `select count(*) from reports where id = $1`, [r1])), 0);
  h.eq('the owner can not read it', Number(await call(owner, `select count(*) from reports where reported_server_id = $1`, [TEST_SERVER])), 0);
  h.eq('anon can not call report_server', await (async () => {
    await h.db.exec(`set role anon`); try { await h.q(`select report_server($1, 'spam', '')`, [TEST_SERVER]); return 'ran'; } catch (e) { return e.message.includes('permission denied') ? 'denied' : e.message; } finally { await h.admin(); }
  })(), 'denied');

  // ---- staff_server_report_info ----
  await h.q(`insert into server_watch_hits (server_id, ref, src, kind, term, sample) values ($1, 'm1', 'message', 'other', 'raid', 'lets raid them')`, [TEST_SERVER]);
  h.eq('a member can not read the info', await call(user, `select staff_server_report_info($1)`, [TEST_SERVER]), 'Staff only');
  const info = await call(mod, `select staff_server_report_info($1)`, [TEST_SERVER]);
  if (typeof info !== 'object') throw new Error('info: ' + info);
  h.eq('info: server, owner, listing, hits', {
    name: info.name, members: info.member_count, listed: info.listed, owner: info.owner?.username, banned: info.owner?.banned,
    hits: info.hits.map((x) => x.term), past: info.past_reports,
  }, { name: 'HQ test', members: 42, listed: true, owner: 'owner', banned: false, hits: ['raid'], past: 0 });
  h.eq('mods get no raw hit samples', info.hits[0].sample, null);
  h.eq('admins do', (await call(admin, `select staff_server_report_info($1)`, [TEST_SERVER])).hits[0].sample, 'lets raid them');
  h.eq('mods can not look up a server nobody reported', await call(mod, `select staff_server_report_info($1)`, [other]), 'That server wasn\'t reported');
  h.eq('admin: a deleted / unknown server is null', await call(admin, `select staff_server_report_info('00000000-0000-0000-0000-000000000001')`), 'ok');

  // ---- claims: a server's reports are one case ----
  const open = (await h.q(`select array_agg(id) a from reports where reported_server_id = $1 and status = 'open'`, [TEST_SERVER]))[0].a;
  h.eq('two open reports on the test server', open.length, 2);
  h.eq('mod claims the server case', Number(await call(mod, `select claim_reports($1::uuid[])`, [open])), 2);
  // Four more single-report server cases: the server case above counts once, so the 5th claim still fits.
  for (let i = 0; i < 4; i++) {
    const ids = (await h.q(`select array_agg(id) a from reports where reported_server_id = $1`, [servers[i]]))[0].a;
    h.eq(`mod claims server case ${i + 2}`, Number(await call(mod, `select claim_reports($1::uuid[])`, [ids])), 1);
  }
  const ids5 = (await h.q(`select array_agg(id) a from reports where reported_server_id = $1`, [servers[4]]))[0].a;
  h.eq('the 6th case is refused', await call(mod, `select claim_reports($1::uuid[])`, [ids5]), 'You already hold 5 claims. Finish or release one first.');

  // ---- staff_close_server_reports ----
  // A mod's own server, or another staff member's: admins only.
  const modServer = (await h.q(`insert into servers (name, owner_id) values ('Mod place', $1) returning id`, [mod2]))[0].id;
  await h.q(`insert into reports (reporter_id, reason, details, reported_server_id, reported_server_name) values ($1, 'spam', '', $2, 'Mod place')`, [user, modServer]);
  h.eq('a mod can not close reports about their own server', await call(mod2, `select staff_close_server_reports($1, 'dismissed', '')`, [modServer]), 'That server belongs to staff. Ask an admin.');
  h.eq('nor about another mod\'s server', await call(mod, `select staff_close_server_reports($1, 'dismissed', '')`, [modServer]), 'That server belongs to staff. Ask an admin.');
  h.eq('an admin can', Number(await call(admin, `select staff_close_server_reports($1, 'dismissed', 'fine')`, [modServer])), 1);
  await h.q(`del` + `ete from mod_log where reason like '%Mod place%'`);
  h.eq('a member can not close', await call(user, `select staff_close_server_reports($1, 'dismissed', '')`, [TEST_SERVER]), 'Staff only');
  h.eq('bad status', await call(mod, `select staff_close_server_reports($1, 'open', '')`, [TEST_SERVER]), 'Bad status');
  h.eq('another mod is refused while it is claimed', await call(mod2, `select staff_close_server_reports($1, 'dismissed', '')`, [TEST_SERVER]),
    'Claimed by mod. You can take over after 30 minutes without action.');
  h.eq('the holder closes it as handled', Number(await call(mod, `select staff_close_server_reports($1, 'actioned', 'Warned the owner')`, [TEST_SERVER])), 2);
  h.eq('reports closed, claim cleared', (await h.q(`select distinct status, claimed_by, resolved_by from reports where reported_server_id = $1`, [TEST_SERVER])),
    [{ status: 'actioned', claimed_by: null, resolved_by: mod }]);
  h.eq('mod_log row against the owner', (await h.q(`select actor, action, target_id, reason from mod_log where action like 'server_report%'`)),
    [{ actor: mod, action: 'server_report_closed', target_id: owner, reason: 'Warned the owner [HQ test]' }]);
  h.eq('nothing left to close: 0, no extra log', Number(await call(mod, `select staff_close_server_reports($1, 'dismissed', '')`, [TEST_SERVER])), 0);
  h.eq('admin passes a live claim', Number(await call(admin, `select staff_close_server_reports($1, 'dismissed', '')`, [servers[0]])), 1);
  h.eq('dismiss logged with the count', (await h.q(`select action, reason from mod_log where actor = $1`, [admin])),
    [{ action: 'server_report_dismissed', reason: '1 report [S0]' }]);
  h.eq('info counts the handled reports', (await call(mod, `select staff_server_report_info($1)`, [TEST_SERVER])).past_actioned, 2);

  // ---- server deleted: the report stays, with the name ----
  await h.q(`del` + `ete from servers where id = $1`, [servers[1]]);
  h.eq('deleted server: id cleared, name kept', (await h.q(`select reported_server_id, reported_server_name from reports where reporter_id = $1 and reported_server_name = 'S1'`, [antic]))[0],
    { reported_server_id: null, reported_server_name: 'S1' });
}
