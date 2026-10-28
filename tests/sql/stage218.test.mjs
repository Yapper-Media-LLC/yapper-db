// 218: request_guard also sets the response header X-Yapper-Uid (the verified token's sub) for signed-in requests, so
// our own API host can count requests per account from Caddy's log. Everything 190 checked about the guard still
// holds: anon/service/odd subs pass without a header, held-back accounts still get PT429, it still never writes and
// works inside a READ ONLY transaction (PostgREST's GETs), and the header can't carry anything but a canonical uuid.
// Same base as stage190 (001..024 + flags + stand-ins), then 190 and 218 (twice: re-runnable).
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.mod_log (
  id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid, message_id uuid,
  reason text not null default '', created_at timestamptz not null default now());
create table if not exists public.site_moderators (user_id uuid primary key);
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
  await h.db.exec(read('218_request_guard_uid_header.sql')); // re-runnable

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  await h.db.query(`update public.feature_flags set mode = 'everyone' where key = 'request_limits'`);

  /** The guard as PostgREST runs it for a GET: read-only transaction, role switched, claims set; then what PostgREST
   *  would read back as response.headers in the same transaction. */
  async function guard(role, claims, legacySub = '') {
    await h.db.exec(`reset role`);
    await h.db.query(`select set_config('request.jwt.claim.sub', $1, false), set_config('request.jwt.claims', $2, false), set_config('response.headers', '', false)`, [legacySub, claims ? JSON.stringify(claims) : '']);
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
      await h.db.query(`select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '', false)`);
    }
  }
  const asUser = (id) => guard('authenticated', { sub: id, role: 'authenticated' });

  // ---- no user: no header, no error ----
  h.eq('anon (no token): nothing', await guard('anon', null), { err: null, headers: null });
  h.eq('anon key claims: nothing', await guard('anon', { role: 'anon' }), { err: null, headers: null });
  h.eq('service role: nothing', await guard('service_role', { role: 'service_role' }), { err: null, headers: null });
  h.eq('odd sub: nothing', await guard('authenticated', { sub: 'x"}]; drop', role: 'authenticated' }), { err: null, headers: null });

  // ---- signed in: the header, as PostgREST's array of single-key objects, in a read-only transaction ----
  h.eq('user gets X-Yapper-Uid', await asUser(amy), { err: null, headers: [{ 'X-Yapper-Uid': amy }] });
  h.eq('upper-case sub comes out canonical', await asUser(amy.toUpperCase()), { err: null, headers: [{ 'X-Yapper-Uid': amy }] });
  h.eq('legacy claim.sub fallback also tagged', await guard('authenticated', null, bob), { err: null, headers: [{ 'X-Yapper-Uid': bob }] });
  h.eq('claims win over the legacy setting', await guard('authenticated', { sub: amy, role: 'authenticated' }, bob), { err: null, headers: [{ 'X-Yapper-Uid': amy }] });

  // ---- held back: still PT429 (the header goes with the rolled-back transaction; 429s aren't counted anyway) ----
  await h.db.query(`insert into public.request_throttle (user_id, until, enforced) values ($1, now() + interval '15 minutes', true)`, [bob]);
  h.eq('held-back user still gets PT429', (await asUser(bob)).err, 'PT429');
  h.eq('others still pass, tagged', await asUser(amy), { err: null, headers: [{ 'X-Yapper-Uid': amy }] });
  await h.db.query(`update public.feature_flags set mode = 'off' where key = 'request_limits'`);
  h.eq('flag off: held row ignored, still tagged', await asUser(bob), { err: null, headers: [{ 'X-Yapper-Uid': bob }] });

  // ---- the guard still never writes, and is still callable by exactly the PostgREST roles ----
  await h.admin();
  const fn = await h.one(`select provolatile, prosecdef, proconfig from pg_proc where oid = 'public.request_guard()'::regprocedure`);
  h.eq('still stable security definer with search_path', [fn.provolatile, fn.prosecdef, fn.proconfig], ['s', true, ['search_path=public']]);
  const grants = await h.q(`select r.rolname from pg_roles r where has_function_privilege(r.oid, 'public.request_guard()', 'execute') and r.rolname in ('anon','authenticated','service_role') order by 1`);
  h.eq('execute for the PostgREST roles', grants.map((g) => g.rolname), ['anon', 'authenticated', 'service_role']);
  h.eq('no throttle rows written by the guard', (await h.one(`select count(*)::int n from public.request_throttle`)).n, 1);
}
