// 660: 2FA backup codes and the email reset. Only the service role may call any of it; codes are one-time, stored
// hashed, rate limited; the email reset waits, can be cancelled, and its links are stored hashed.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '660_mfa_recovery.sql'), 'utf8');

const STANDINS = String.raw`
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[], users uuid[]);
create table public.t660 (k text primary key, v boolean);
grant select on public.t660 to authenticated;
create or replace function public.is_site_admin() returns boolean language sql security definer as $$ select coalesce((select v from public.t660 where k = 'admin'), false) $$;
`;

export default async function (h) {
  for (const bad of ['drop ', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`660 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('660 runs', () => h.db.exec(MIG));
  await h.ok('660 re-runs cleanly', () => h.db.exec(MIG));
  const flag = await h.one(`select mode, users::text[] u, servers::text[] s from public.feature_flags where key = 'mfa_recovery'`);
  h.eq('flag is test-only', [flag.mode, flag.u, flag.s], ['test', ['00000000-0000-4000-8000-00000000a001'], ['00000000-0000-4000-8000-00000000b001']]);

  const a = await h.signup('a660@x.test', 'a660');
  const b = await h.signup('b660@x.test', 'b660');
  const svc = async () => { await h.admin(); await h.db.exec('set role service_role'); };

  // Nobody but the service role.
  for (const who of [a, null]) {
    await h.as(who);
    await h.fails(`${who ? 'user' : 'anon'} can't make codes`, `select public.mfa_backup_codes_new($1, 'x')`, [a]);
    await h.fails(`${who ? 'user' : 'anon'} can't use a code`, `select public.mfa_backup_code_use($1, 'aaaaaaaaaa', 'x')`, [a]);
    await h.fails(`${who ? 'user' : 'anon'} can't start a reset`, `select public.mfa_recovery_start($1, 'x')`, [a]);
    await h.fails(`${who ? 'user' : 'anon'} can't confirm a reset`, `select public.mfa_recovery_confirm(repeat('a', 64), 'x')`);
    await h.fails(`${who ? 'user' : 'anon'} can't cancel a reset`, `select public.mfa_recovery_cancel(null, $1, 'x')`, [a]);
    await h.fails(`${who ? 'user' : 'anon'} can't read status`, `select public.mfa_recovery_status($1)`, [a]);
    await h.fails(`${who ? 'user' : 'anon'} can't write the log`, `select public.mfa_log($1, 'x', 'x')`, [a]);
    await h.fails(`${who ? 'user' : 'anon'} can't read code hashes`, `select * from public.mfa_backup_codes`);
    await h.fails(`${who ? 'user' : 'anon'} can't read reset requests`, `select * from public.mfa_recovery_requests`);
  }
  await h.as(a);
  h.eq('a user sees no security log', (await h.q(`select * from public.security_log`)).length, 0);

  // Codes.
  await svc();
  const codes = (await h.one(`select public.mfa_backup_codes_new($1, '1.1.1.1') c`, [a])).c;
  h.eq('10 codes', codes.length, 10);
  h.eq('codes are 10 easy characters', codes.every((c) => /^[2-9a-km-np-z]{10}$/.test(c)), true);
  h.eq('codes are different', new Set(codes).size, 10);
  const stored = await h.q(`select code_hash from public.mfa_backup_codes where user_id = $1`, [a]);
  h.eq('only hashes are stored', stored.some((r) => codes.includes(r.code_hash)), false);
  h.eq('status counts them', (await h.one(`select public.mfa_recovery_status($1) s`, [a])).s.codes_left, 10);

  const use = async (u, c, ip = '1.1.1.1') => (await h.one(`select public.mfa_backup_code_use($1, $2, $3) r`, [u, c, ip])).r;
  const typed = `${codes[0].slice(0, 5).toUpperCase()}-${codes[0].slice(5)} `;
  h.eq('a code works, typed with caps and a dash', (await use(a, typed)).ok, true);
  h.eq('the same code only works once', !!(await use(a, codes[0])).error, true);
  h.eq('a code is tied to its account', !!(await use(b, codes[1])).error, true);
  h.eq('9 left', (await h.one(`select public.mfa_recovery_status($1) s`, [a])).s.codes_left, 9);

  const used = await use(a, codes[1]);
  await h.db.query(`select public.mfa_backup_code_unuse($1)`, [used.id]);
  h.eq('unuse gives a code back', (await use(a, codes[1])).ok, true);

  // Codes from before the current authenticator (p_since) don't count.
  const since = async (u, c, t) => (await h.one(`select public.mfa_backup_code_use($1, $2, '1.1.1.1', $3::timestamptz) r`, [u, c, t])).r;
  h.eq('a code older than the authenticator is refused', !!(await since(a, codes[2], new Date(Date.now() + 60_000).toISOString())).error, true);
  h.eq('a code newer than it works', (await since(a, codes[2], new Date(Date.now() - 3600_000).toISOString())).ok, true);

  // Rate limit: wrong codes for a fresh account.
  const c = await h.signup('c660@x.test', 'c660');
  await svc();
  const cc = (await h.one(`select public.mfa_backup_codes_new($1, null) c`, [c])).c;
  for (let i = 0; i < 4; i++) await use(c, 'zzzzzzzzzz', '2.2.2.2');
  h.eq('4 wrong codes then a right one still works', (await use(c, cc[0], '2.2.2.2')).ok, true);
  await use(c, 'zzzzzzzzzz', '2.2.2.2');
  h.eq('after 5 wrong codes even a right one is refused', /too many/i.test((await use(c, cc[1], '2.2.2.2')).error ?? ''), true);
  h.eq('fails are logged', (await h.one(`select count(*)::int n from public.security_log where user_id = $1 and event = 'backup_code_fail'`, [c])).n, 5);

  // New codes replace old ones.
  const codes2 = (await h.one(`select public.mfa_backup_codes_new($1, null) c`, [a])).c;
  h.eq('old codes stop working after new ones', !!(await use(a, codes[5])).error, true);
  h.eq('new codes work', (await use(a, codes2[0])).ok, true);

  // Email reset.
  const start = async (u, wait = '24 hours') => (await h.one(`select public.mfa_recovery_start($1, '1.1.1.1', $2::interval) r`, [u, wait])).r;
  const confirm = async (t) => (await h.one(`select public.mfa_recovery_confirm($1, '1.1.1.1') r`, [t])).r;
  const cancel = async (t, u = null) => (await h.one(`select public.mfa_recovery_cancel($1, $2, '1.1.1.1') r`, [t, u])).r;
  const r1 = await start(a);
  h.eq('start gives two 64-char tokens', [/^[0-9a-f]{64}$/.test(r1.confirm), /^[0-9a-f]{64}$/.test(r1.cancel)], [true, true]);
  const row = await h.one(`select confirm_hash, cancel_hash from public.mfa_recovery_requests where id = $1`, [r1.id]);
  h.eq('tokens are stored hashed', [row.confirm_hash === r1.confirm, row.cancel_hash === r1.cancel], [false, false]);
  h.eq('one open request at a time', !!(await start(a)).error, true);
  h.eq('too early: wait', (await confirm(r1.confirm)).wait, true);
  h.eq('the cancel token is not a confirm token', !!(await confirm(r1.cancel)).error, true);
  h.eq('a made-up token fails', !!(await confirm('a'.repeat(64))).error, true);
  h.eq('junk fails', !!(await confirm("' or 1=1 --")).error, true);
  h.eq('status shows it pending', !!(await h.one(`select public.mfa_recovery_status($1) s`, [a])).s.pending, true);
  h.eq('cancel by link', (await cancel(r1.cancel)).cancelled, 1);
  h.eq('the same cancel link again: no second cancel', !!(await cancel(r1.cancel)).error, true);
  await h.db.exec(`update public.mfa_recovery_requests set ready_at = now() - interval '1 minute' where id = '${r1.id}'`);
  h.eq('cancelled stays cancelled even after the wait', /cancelled/.test((await confirm(r1.confirm)).error ?? ''), true);

  const r2 = await start(a, '0 seconds');
  const ok = await confirm(r2.confirm);
  h.eq('after the wait it confirms for the right account', [ok.ok, ok.user_id, !!ok.created_at], [true, a, true]);
  h.eq('a link works once', !!(await confirm(r2.confirm)).error, true);
  await h.db.query(`select public.mfa_recovery_reopen($1)`, [r2.id]);
  h.eq('reopen lets it be confirmed again', (await confirm(r2.confirm)).ok, true);
  h.eq('an old cancel link can’t cancel a later request', !!(await cancel(r1.cancel)).error, true);

  // A cancel while it was 'done' (removing the authenticator failed) keeps it from being reopened.
  await h.db.exec(`update public.mfa_recovery_requests set status = 'done', closed_at = now() - interval '1 second' where id = '${r2.id}'`);
  await cancel(null, a);
  await h.db.query(`select public.mfa_recovery_reopen($1)`, [r2.id]);
  h.eq('no reopen after a cancel', (await h.one(`select status from public.mfa_recovery_requests where id = $1`, [r2.id])).status, 'done');
  await h.db.exec(`update public.mfa_recovery_requests set closed_at = now() - interval '1 second' where id = '${r2.id}';
                   update public.security_log set created_at = now() - interval '1 minute' where event = 'recovery_cancel';`);
  h.eq('the email cancel link on a used request says too late', /too late/i.test((await cancel(r2.cancel)).error ?? ''), true);
  await h.db.query(`select public.mfa_recovery_reopen($1)`, [r2.id]);
  h.eq('no reopen after an email cancel either', (await h.one(`select status from public.mfa_recovery_requests where id = $1`, [r2.id])).status, 'done');

  const r3 = await start(a);
  h.eq('third start of the day goes', !!r3.confirm, true);
  h.eq('signed-in cancel stops it', (await cancel(null, a)).cancelled, 1);
  h.eq('a fourth start in a day is refused', /too many/i.test((await start(a)).error ?? ''), true);

  // Bad links: 30 an hour per IP, then refused without more log rows.
  for (let i = 0; i < 30; i++) await h.one(`select public.mfa_recovery_confirm($1, '9.9.9.9') r`, [i.toString(16).padStart(64, 'b')]);
  const before = (await h.one(`select count(*)::int n from public.security_log where ip = '9.9.9.9'`)).n;
  const lim = (await h.one(`select public.mfa_recovery_confirm($1, '9.9.9.9') r`, ['c'.repeat(64)])).r;
  const lim2 = (await h.one(`select public.mfa_recovery_cancel($1, null, '9.9.9.9') r`, ['c'.repeat(64)])).r;
  const after = (await h.one(`select count(*)::int n from public.security_log where ip = '9.9.9.9'`)).n;
  h.eq('bad links: limited, and the flood stops writing rows', [/too many/i.test(lim.error), /too many/i.test(lim2.error), after - before], [true, true, 0]);

  // mfa_cleared: codes and open requests are gone after 2FA is removed.
  const r4 = await start(b);
  await h.one(`select public.mfa_backup_codes_new($1, null) c`, [b]);
  await h.db.query(`select public.mfa_cleared($1)`, [b]);
  const sb = (await h.one(`select public.mfa_recovery_status($1) s`, [b])).s;
  h.eq('cleared: no codes, no pending', [sb.codes_left, sb.pending], [0, null]);
  h.eq('cleared: its link is dead', !!(await confirm(r4.confirm)).error, true);

  // Admins read the log.
  await h.admin();
  await h.db.exec(`insert into public.t660 values ('admin', true)`);
  await h.as(a);
  h.eq('an admin reads the security log', (await h.q(`select * from public.security_log`)).length > 0, true);
  await h.fails('nobody writes the log directly', `insert into public.security_log (event) values ('x')`);
}
