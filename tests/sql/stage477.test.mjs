// 477: request_guard refuses an aal1 token (password done, 2FA code not yet) from an account that has a verified 2FA
// factor. aal2 passes; accounts without 2FA pass at aal1; an unverified factor doesn't count; anon and the service
// role are untouched; held-back accounts still get PT429; the header and the read-only behaviour from 218 stay.
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.mod_log (
  id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid, message_id uuid,
  reason text not null default '', created_at timestamptz not null default now());
create table if not exists public.site_moderators (user_id uuid primary key);
create table if not exists auth.mfa_factors (
  id uuid primary key default gen_random_uuid(), user_id uuid not null, status text not null, factor_type text not null default 'totp');
create index if not exists mfa_factors_user_id_idx on auth.mfa_factors (user_id);
`;

export default async function (h) {
  const { readFileSync } = await import('node:fs');
  const { join, dirname } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const dir = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'supabase', 'migrations');
  const read = (f) => readFileSync(join(dir, f), 'utf8');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(read('190_request_limits.sql'));
  await h.db.exec(read('218_request_guard_uid_header.sql'));
  const MIG = read('477_mfa_before_data.sql');
  await h.ok('477 runs', () => h.db.exec(MIG));
  await h.ok('477 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy'); // 2FA on
  const bob = await h.signup('bob@test.dev', 'bob'); // no 2FA
  const cat = await h.signup('cat@test.dev', 'cat'); // started 2FA setup, never verified
  await h.admin();
  await h.q(`insert into auth.mfa_factors (user_id, status) values ($1, 'verified'), ($2, 'unverified')`, [amy, cat]);
  await h.db.query(`update public.feature_flags set mode = 'everyone' where key = 'request_limits'`);

  async function guard(role, claims) {
    await h.db.exec(`reset role`);
    await h.db.query(`select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', $1, false), set_config('response.headers', '', false)`, [claims ? JSON.stringify(claims) : '']);
    try {
      await h.db.exec(`begin transaction read only; set local role ${role};`);
      await h.db.exec(`select public.request_guard()`);
      const hdr = (await h.one(`select nullif(current_setting('response.headers', true), '') as v`)).v;
      await h.db.exec(`commit`);
      return { err: null, headers: hdr ? JSON.parse(hdr) : null };
    } catch (e) {
      await h.db.exec(`rollback`).catch(() => undefined);
      return { err: e.code ?? e.message, headers: null };
    } finally {
      await h.db.exec(`reset role`);
      await h.db.query(`select set_config('request.jwt.claims', '', false)`);
    }
  }
  const as = (id, aal) => guard('authenticated', { sub: id, role: 'authenticated', ...(aal ? { aal } : {}) });

  h.eq('2FA account at aal1: refused', (await as(amy, 'aal1')).err, 'PT403');
  h.eq('2FA account with no aal claim: refused', (await as(amy)).err, 'PT403');
  h.eq('2FA account at aal2: passes, tagged', await as(amy, 'aal2'), { err: null, headers: [{ 'X-Yapper-Uid': amy }] });
  h.eq('no 2FA at aal1: passes', await as(bob, 'aal1'), { err: null, headers: [{ 'X-Yapper-Uid': bob }] });
  h.eq('unverified factor does not count', await as(cat, 'aal1'), { err: null, headers: [{ 'X-Yapper-Uid': cat }] });
  h.eq('anon: nothing', await guard('anon', null), { err: null, headers: null });
  h.eq('service role: nothing', await guard('service_role', { role: 'service_role' }), { err: null, headers: null });

  await h.admin();
  await h.db.query(`insert into public.request_throttle (user_id, until, enforced) values ($1, now() + interval '15 minutes', true)`, [bob]);
  h.eq('held-back account still gets PT429', (await as(bob, 'aal1')).err, 'PT429');

  await h.admin();
  const fn = await h.one(`select provolatile, prosecdef, proconfig from pg_proc where oid = 'public.request_guard()'::regprocedure`);
  h.eq('still stable security definer with search_path', [fn.provolatile, fn.prosecdef, fn.proconfig], ['s', true, ['search_path=public']]);
  const grants = await h.q(`select r.rolname from pg_roles r where has_function_privilege(r.oid, 'public.request_guard()', 'execute') and r.rolname in ('anon','authenticated','service_role') order by 1`);
  h.eq('execute for the PostgREST roles', grants.map((g) => g.rolname), ['anon', 'authenticated', 'service_role']);
}
