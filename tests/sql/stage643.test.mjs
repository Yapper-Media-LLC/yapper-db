// 643: report claims. claim_reports / unclaim_reports (staff, flag report_claims), the 30-minute window, admin take-over
// with its mod_log row, the 5-case cap, and the trigger that clears a claim when a report is closed.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');
const TEST_SERVER = '00000000-0000-4000-8000-00000000b001';

export default async function (h) {
  await h.admin();
  await h.db.exec(`
    create table if not exists public.staff_standin (user_id uuid primary key);
    create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
      target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
  `);
  await h.db.exec(mig('643_report_claims.sql'));
  await h.ok('643 re-runs cleanly', () => h.db.exec(mig('643_report_claims.sql')));
  h.eq('flag row in test for Antic and the HQ test server', (await h.q(`select mode, servers, users from feature_flags where key = 'report_claims'`))[0],
    { mode: 'test', servers: [TEST_SERVER], users: ['00000000-0000-4000-8000-00000000a001'] });

  const admin = await h.signup('admin@test.dev', 'admin');
  const mod = await h.signup('mod@test.dev', 'mod');
  const mod2 = await h.signup('mod2@test.dev', 'mod2');
  const outsider = await h.signup('out@test.dev', 'outsider');
  const user = await h.signup('u@test.dev', 'user');
  const bad = await h.signup('b@test.dev', 'bad');
  const bad2 = await h.signup('b2@test.dev', 'bad2');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into staff_standin values ($1), ($2), ($3), ($4)`, [mod, mod2, admin, outsider]);
  // The flag is in test mode: members of the HQ test server (mod, mod2, admin) have it, outsider does not.
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'HQ test', $2)`, [TEST_SERVER, admin]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4)`, [TEST_SERVER, mod, mod2, admin]);

  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const rep = async (target) => (await h.q(`insert into reports (reporter_id, target_id, reason, details) values ($1, $2, 'spam', '') returning id`, [user, target]))[0].id;
  const claimOf = async (id) => (await h.q(`select claimed_by, claimed_at from reports where id = $1`, [id]))[0];
  const r1 = await rep(bad); const r2 = await rep(bad);

  h.eq('a member can not claim', await call(user, `select claim_reports(array[$1]::uuid[])`, [r1]), 'Staff only');
  h.eq('staff without the flag can not claim', await call(outsider, `select claim_reports(array[$1]::uuid[])`, [r1]), 'Not available');
  h.eq('empty list: 0', Number(await call(mod, `select claim_reports('{}'::uuid[])`)), 0);
  h.eq('mod claims the two reports of a case', Number(await call(mod, `select claim_reports(array[$1, $2]::uuid[])`, [r1, r2])), 2);
  h.eq('claimed by the mod', (await claimOf(r1)).claimed_by, mod);
  h.eq('claimed_at set', !!(await claimOf(r2)).claimed_at, true);
  h.eq('another mod is refused with the holder name', await call(mod2, `select claim_reports(array[$1, $2]::uuid[])`, [r1, r2]), 'Claimed by mod. You can take over after 30 minutes without action.');
  h.eq('no take-over row for a refused claim', (await h.q(`select count(*)::int n from mod_log where action = 'report_claim_taken'`))[0].n, 0);
  h.eq('still the mod', (await claimOf(r1)).claimed_by, mod);

  // Refreshing my own claim moves the timestamp.
  await h.q(`update reports set claimed_at = now() - interval '10 minutes' where id in ($1, $2)`, [r1, r2]);
  h.eq('the holder refreshes the claim', Number(await call(mod, `select claim_reports(array[$1, $2]::uuid[])`, [r1, r2])), 2);
  h.eq('claimed_at is fresh again', (await h.q(`select (claimed_at > now() - interval '1 minute') fresh from reports where id = $1`, [r1]))[0].fresh, true);

  // Admin takes over a live claim; it is logged against the reported person.
  h.eq('admin takes over at any time', Number(await call(admin, `select claim_reports(array[$1, $2]::uuid[])`, [r1, r2])), 2);
  h.eq('now the admin', (await claimOf(r2)).claimed_by, admin);
  h.eq('take-over logged', (await h.q(`select actor, target_id, reason from mod_log where action = 'report_claim_taken'`))[0], { actor: admin, target_id: bad, reason: 'Took over the case from mod' });

  // 30 minutes without action: the claim is free for anyone.
  await h.q(`update reports set claimed_at = now() - interval '31 minutes' where id in ($1, $2)`, [r1, r2]);
  h.eq('a stale claim can be taken by another mod', Number(await call(mod2, `select claim_reports(array[$1, $2]::uuid[])`, [r1, r2])), 2);
  h.eq('now mod2', (await claimOf(r1)).claimed_by, mod2);
  h.eq('a plain take of a stale claim is not logged as a take-over', (await h.q(`select count(*)::int n from mod_log where action = 'report_claim_taken'`))[0].n, 1);

  // Release: own claims only, admins anyone's.
  h.eq('mod can not release mod2 claim', Number(await call(mod, `select unclaim_reports(array[$1, $2]::uuid[])`, [r1, r2])), 0);
  h.eq('still mod2', (await claimOf(r1)).claimed_by, mod2);
  h.eq('mod2 releases', Number(await call(mod2, `select unclaim_reports(array[$1, $2]::uuid[])`, [r1, r2])), 2);
  h.eq('released', (await claimOf(r1)), { claimed_by: null, claimed_at: null });
  h.eq('a member can not release', await call(user, `select unclaim_reports(array[$1]::uuid[])`, [r1]), 'Staff only');
  h.eq('mod claims again', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('admin releases a mod claim', Number(await call(admin, `select unclaim_reports(array[$1]::uuid[])`, [r1])), 1);

  // Closing a report clears its claim, whichever way it closes.
  h.eq('mod claims r1 and r2', Number(await call(mod, `select claim_reports(array[$1, $2]::uuid[])`, [r1, r2])), 2);
  await h.q(`update reports set status = 'actioned', resolved_by = $2, resolved_at = now() where id = $1`, [r1, mod]);
  h.eq('closed report has no claim', (await claimOf(r1)), { claimed_by: null, claimed_at: null });
  h.eq('the open one keeps it', (await claimOf(r2)).claimed_by, mod);
  await h.q(`update reports set status = 'dismissed' where id = $1`, [r2]);
  h.eq('dismissed report has no claim', (await claimOf(r2)).claimed_by, null);
  h.eq('a closed report can not be claimed', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [r1])), 0);
  h.eq('and stays unclaimed', (await claimOf(r1)).claimed_by, null);

  // Cap: five cases at once, counted by reported person, not by report.
  const targets = [];
  for (let i = 0; i < 5; i++) targets.push(await h.signup(`t${i}@test.dev`, `t${i}`));
  await h.admin();
  const ids = [];
  for (const t of targets) ids.push(await rep(t));
  for (const id of ids) h.eq('claims case ' + id.slice(0, 4), Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [id])), 1);
  const sixth = await rep(bad2);
  h.eq('a sixth case is refused', await call(mod, `select claim_reports(array[$1]::uuid[])`, [sixth]), 'You already hold 5 claims. Finish or release one first.');
  const more = await rep(targets[0]);
  h.eq('a new report on a held case still counts as that case', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [more])), 1);
  h.eq('refreshing a held case is fine at the cap', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [ids[1]])), 1);
  await h.q(`update reports set claimed_at = now() - interval '31 minutes' where id = $1`, [ids[2]]);
  h.eq('a stale claim frees a slot', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [sixth])), 1);
  h.eq('admins have the same cap', await (async () => {
    for (const id of ids) await h.q(`update reports set claimed_by = $2, claimed_at = now() where id = $1`, [id, admin]);
    return call(admin, `select claim_reports(array[$1]::uuid[])`, [sixth]);
  })(), 'You already hold 5 claims. Finish or release one first.');
  h.eq('too many at once', String(await call(mod, `select claim_reports((select array_agg(gen_random_uuid()) from generate_series(1, 201)))`)).includes('Too many'), true);
}
