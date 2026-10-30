// 665: report claims for leads. Head mods and Management take over or unclaim someone else's live claim at any time
// (logged), except an admin's claim (admins and Management only); a mod still unclaims only their own and is refused
// a live claim; the flag text is updated.
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
  // Stand-ins for is_staff (048), is_head_mod (365) and is_site_manager (537).
  await h.db.exec(`
    create table if not exists public.staff_standin (user_id uuid primary key, head boolean not null default false, manager boolean not null default false);
    create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
      target_id uuid, message_id uuid, reason text not null default '', created_at timestamptz not null default now());
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
    create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid() and head) $$;
    create or replace function public.is_site_manager() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid() and manager) $$;
  `);
  await h.db.exec(mig('643_report_claims.sql'));
  // 663 (server reports) runs before 665 live and adds this column, which 665's claim_reports counts cases by.
  await h.db.exec('alter table public.reports add column if not exists reported_server_id uuid');
  await h.db.exec(mig('665_report_claims_leads.sql'));
  await h.ok('665 re-runs cleanly', () => h.db.exec(mig('665_report_claims_leads.sql')));
  h.eq('flag text mentions head mods', (await h.q(`select description like '%Head mods, Management and admins%' d from feature_flags where key = 'report_claims'`))[0].d, true);

  const mod = await h.signup('mod@test.dev', 'mod');
  const mod2 = await h.signup('mod2@test.dev', 'mod2');
  const head = await h.signup('head@test.dev', 'head');
  const boss = await h.signup('boss@test.dev', 'boss');
  const user = await h.signup('u@test.dev', 'user');
  const admin = await h.signup('admin@test.dev', 'admin');
  const bad = await h.signup('b@test.dev', 'bad');
  await h.admin();
  await h.q(`insert into staff_standin (user_id, head, manager) values ($1, false, false), ($2, false, false), ($3, true, false), ($4, true, true)`, [mod, mod2, head, boss]);
  await h.q(`insert into staff_standin (user_id) values ($1)`, [admin]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'HQ test', $2)`, [TEST_SERVER, boss]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4), ($1, $5), ($1, $6)`, [TEST_SERVER, mod, mod2, head, admin, boss]);

  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const r1 = (await h.q(`insert into reports (reporter_id, target_id, reason, details) values ($1, $2, 'spam', '') returning id`, [user, bad]))[0].id;
  const holder = async () => (await h.q(`select claimed_by from reports where id = $1`, [r1]))[0].claimed_by;
  const logs = async (action) => h.q(`select actor, target_id, reason from mod_log where action = $1 order by created_at`, [action]);

  h.eq('the helper is not callable directly', String(await call(mod, `select report_claim_may_override($1)`, [mod])).includes('permission denied'), true);

  // A mod claims; another mod is refused and can't unclaim it.
  h.eq('mod claims', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('mod2 can not take a live claim', await call(mod2, `select claim_reports(array[$1]::uuid[])`, [r1]), 'Claimed by mod. You can take over after 30 minutes without action.');
  h.eq('mod2 can not unclaim it', Number(await call(mod2, `select unclaim_reports(array[$1]::uuid[])`, [r1])), 0);
  h.eq('still mod', await holder(), mod);

  // A head mod takes over at once, logged.
  h.eq('head mod takes over', Number(await call(head, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('now the head mod', await holder(), head);
  h.eq('take-over logged', (await logs('report_claim_taken'))[0], { actor: head, target_id: bad, reason: 'Took over the case from mod' });

  // Management unclaims the head mod's claim, logged.
  h.eq('Management unclaims it', Number(await call(boss, `select unclaim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('nobody holds it', await holder(), null);
  h.eq('unclaim logged', (await logs('report_claim_released'))[0], { actor: boss, target_id: bad, reason: 'Unclaimed the case from head' });

  // Unclaiming your own claim: allowed for a mod, not logged.
  h.eq('mod claims again', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('mod unclaims their own', Number(await call(mod, `select unclaim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('own unclaim is not logged', (await logs('report_claim_released')).length, 1);
  h.eq('a head mod unclaiming their own is not logged either', await (async () => {
    await call(head, `select claim_reports(array[$1]::uuid[])`, [r1]);
    await call(head, `select unclaim_reports(array[$1]::uuid[])`, [r1]);
    return (await logs('report_claim_released')).length;
  })(), 1);
  h.eq('unclaiming nothing logs nothing', await (async () => {
    await call(head, `select unclaim_reports(array[$1]::uuid[])`, [r1]);
    return (await logs('report_claim_released')).length;
  })(), 1);

  // An admin's claim: head mods can't take it over or unclaim it, Management can.
  h.eq('admin claims', Number(await call(admin, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('head mod can not take over an admin claim', await call(head, `select claim_reports(array[$1]::uuid[])`, [r1]), 'Claimed by admin, an admin. Only admins and Management can take that over.');
  h.eq('head mod can not unclaim an admin claim', Number(await call(head, `select unclaim_reports(array[$1]::uuid[])`, [r1])), 0);
  h.eq('still the admin', await holder(), admin);
  h.eq('no log row for the refused unclaim', (await logs('report_claim_released')).length, 1);
  h.eq('Management takes over the admin claim', Number(await call(boss, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('admin unclaims Management', Number(await call(admin, `select unclaim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('logged', (await logs('report_claim_released')).length, 2);

  // Mods still take over a stale claim after 30 minutes.
  h.eq('mod2 claims', Number(await call(mod2, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  await h.q(`update reports set claimed_at = now() - interval '31 minutes' where id = $1`, [r1]);
  h.eq('mod takes a stale claim', Number(await call(mod, `select claim_reports(array[$1]::uuid[])`, [r1])), 1);
  h.eq('now mod', await holder(), mod);
  h.eq('a member still can not unclaim', await call(user, `select unclaim_reports(array[$1]::uuid[])`, [r1]), 'Staff only');
}
