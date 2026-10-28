// 190/191: per-account request limits. The PostgREST pre-request guard lets anon/service/unknown requests through,
// never writes (it runs in READ ONLY transactions for GETs), answers PT429 (HTTP 429) only for held-back accounts the
// request_limits flag covers; request_limits_apply is service-role only, holds back the flag's users in test mode and
// only notices everyone else, never holds back staff, logs once per episode, ignores junk and anything under the floor;
// site admins (not moderators) can lift a hold, and a lifted account isn't held again for one detection window.
// PGlite can't replay every migration: 001..024, flags (031, 041), stand-ins for mod_log and is_staff, then 190 and 191
// twice each (re-runnable). 191's cron/vault/pg_net bits are skipped or never called here (no cron schema).
export const base = 24;

const STANDINS = `
create table if not exists public.mod_log (
  id uuid primary key default gen_random_uuid(),
  actor uuid references public.profiles (id) on delete set null,
  action text not null,
  target_id uuid references public.profiles (id) on delete set null,
  message_id uuid,
  reason text not null default '',
  created_at timestamptz not null default now()
);
alter table public.mod_log enable row level security;
create table if not exists public.site_moderators (user_id uuid primary key);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid());
$$;
`;

export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  const { readFileSync } = await import('node:fs');
  const { join, dirname } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const dir = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'supabase', 'migrations');
  const m190 = readFileSync(join(dir, '190_request_limits.sql'), 'utf8');
  const m191 = readFileSync(join(dir, '191_request_limits_cron.sql'), 'utf8');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(m190);
  await h.db.exec(m190); // re-runnable
  await h.db.exec(m191);
  await h.db.exec(m191);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const mod = await h.signup('mod@test.dev', 'moddy');
  const boss = await h.signup('boss@test.dev', 'boss');
  const cara = await h.signup('cara@test.dev', 'cara');
  await h.admin();
  await h.db.query(`insert into public.site_moderators values ($1)`, [mod]);
  await h.db.query(`insert into public.site_admins (user_id) values ($1)`, [boss]);

  const flag = await h.one(`select mode, users from public.feature_flags where key = 'request_limits'`);
  h.eq('flag seeded in test mode', flag.mode, 'test');
  h.eq('flag seeded with Antic and Test', flag.users.length, 2);
  // In this database, amy stands in for Antic (a flag user); bob is everyone else.
  await h.db.query(`update public.feature_flags set users = array[$1::uuid] where key = 'request_limits'`, [amy]);

  /** Calls the guard as PostgREST would for a GET: read-only transaction, role switched, claims set. Returns the error or null. */
  async function guard(role, claims, legacySub = '') {
    await h.db.exec(`reset role`);
    await h.db.query(`select set_config('request.jwt.claim.sub', $1, false), set_config('request.jwt.claims', $2, false)`, [legacySub, claims ? JSON.stringify(claims) : '']);
    try {
      await h.db.exec(`begin transaction read only; set local role ${role}; select public.request_guard(); commit;`);
      return null;
    } catch (e) {
      await h.db.exec(`rollback`).catch(() => undefined);
      return e;
    } finally {
      await h.db.exec(`reset role`);
      await h.db.query(`select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '', false)`);
    }
  }
  const asUser = (id) => guard('authenticated', { sub: id, role: 'authenticated' });

  async function apply(hits, threshold = 6000) {
    await h.db.exec(`reset role; set role service_role;`);
    try {
      const r = (await h.one(`select public.request_limits_apply($1::jsonb, $2, 10) as r`, [JSON.stringify(hits), threshold])).r;
      // jsonb orders keys its own way; compare in the order the checks below write them.
      return { mode: r.mode, held: r.held, noticed: r.noticed, logged: r.logged };
    } finally {
      await h.db.exec(`reset role`);
    }
  }

  // ---- the guard with nothing recorded ----
  h.eq('anon (no token) passes', await guard('anon', null), null);
  h.eq('anon key claims pass', (await guard('anon', { role: 'anon' })), null);
  h.eq('service role passes', (await guard('service_role', { role: 'service_role' })), null);
  h.eq('odd sub passes, no error', (await guard('authenticated', { sub: 'not-a-uuid', role: 'authenticated' })), null);
  h.eq('user passes with an empty table', await asUser(amy), null);

  // ---- who can do what ----
  await h.as(amy);
  await h.fails('users cannot read request_throttle', `select * from public.request_throttle`);
  await h.fails('users cannot call request_limits_apply', `select public.request_limits_apply('[]'::jsonb, 6000, 10)`);
  await h.fails('users cannot write request_throttle', `insert into public.request_throttle (user_id, until, enforced) values ($1, now() + interval '1 hour', true)`, [bob]);
  await h.as(null);
  await h.fails('anon cannot call request_limits_apply', `select public.request_limits_apply('[]'::jsonb, 6000, 10)`);

  // ---- test mode: amy (flag user) held back, bob only noticed ----
  const r1 = await apply([
    { u: amy, c: 9000, top: 'GET /rest/v1/messages', ua: 'Mozilla/5.0' },
    { u: bob, c: 35000, top: 'GET /rest/v1/messages', ua: 'Mozilla/5.0' },
    { u: mod, c: 5999, top: 'GET /rest/v1/profiles', ua: 'x' },            // under the limit
    { u: 'garbage', c: 99999 },                                              // not a uuid
    { u: '00000000-0000-4000-8000-000000000000', c: 99999 },                 // no such profile
  ]);
  h.eq('test mode result', r1, { mode: 'test', held: 1, noticed: 1, logged: 2 });
  await h.admin();
  const rows = await h.q(`select user_id, enforced, requests, hits from public.request_throttle order by requests`);
  h.eq('rows recorded', rows.map((r) => [r.user_id, r.enforced, r.requests, r.hits]), [[amy, true, 9000, 1], [bob, false, 35000, 1]]);
  const e1 = await asUser(amy);
  h.eq('held-back flag user gets PT429', e1?.code, 'PT429');
  if (!/Too many requests from your account\. Try again after \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC\./.test(e1?.message ?? '')) throw new Error(`✗ PT429 message: ${e1?.message}`);
  h.eq('noticed (not flag) user passes', await asUser(bob), null);
  h.eq('legacy request.jwt.claim.sub is the fallback', (await guard('authenticated', null, amy))?.code, 'PT429');
  h.eq('request.jwt.claims wins over the legacy setting (held)', (await guard('authenticated', { sub: amy, role: 'authenticated' }, bob))?.code, 'PT429');
  h.eq('request.jwt.claims wins over the legacy setting (free)', await guard('authenticated', { sub: bob, role: 'authenticated' }, amy), null);
  h.eq('anon claims ignore a stale legacy sub', await guard('anon', { role: 'anon' }, amy), null);
  h.eq('others pass', await asUser(mod), null);
  const log1 = await h.q(`select action, target_id, actor, reason from public.mod_log order by action`);
  h.eq('one log line each', log1.map((l) => [l.action, l.target_id, l.actor]), [['request_limit', amy, null], ['request_limit_seen', bob, null]]);
  h.eq('log reason', log1[0].reason, '9000 API requests in 10 min, mostly GET /rest/v1/messages');

  // ---- a second run in the same episode: no new log lines, hits counted ----
  const r2 = await apply([{ u: amy, c: 8000, top: 'GET /rest/v1/messages' }, { u: bob, c: 30000 }]);
  h.eq('second run result', r2, { mode: 'test', held: 1, noticed: 1, logged: 0 });
  await h.admin();
  h.eq('no extra log lines', (await h.one(`select count(*)::int n from public.mod_log`)).n, 2);
  h.eq('hits counted', (await h.one(`select hits from public.request_throttle where user_id = $1`, [amy])).hits, 2);

  // ---- the caller can't push the limit under the floor ----
  const r3 = await apply([{ u: mod, c: 999 }], 1);
  h.eq('floor of 1000 per window', r3, { mode: 'test', held: 0, noticed: 0, logged: 0 });

  // ---- everyone: bob is held back now, and that's logged once ----
  await h.admin();
  await h.db.exec(`update public.feature_flags set mode = 'everyone' where key = 'request_limits'`);
  h.eq('noticed row alone does not block', await asUser(bob), null);
  const r4 = await apply([{ u: bob, c: 31000, top: 'GET /rest/v1/messages' }]);
  h.eq('everyone result', r4, { mode: 'everyone', held: 1, noticed: 0, logged: 1 });
  h.eq('bob held back in everyone mode', (await asUser(bob))?.code, 'PT429');
  await h.admin();
  h.eq('bob now has a request_limit line', (await h.one(`select count(*)::int n from public.mod_log where target_id = $1 and action = 'request_limit'`, [bob])).n, 1);
  // Staff are only ever noticed, even in everyone mode (and even if they're on the flag's list).
  await h.db.query(`update public.feature_flags set users = array[$1::uuid, $2::uuid] where key = 'request_limits'`, [amy, boss]);
  const r5 = await apply([{ u: mod, c: 20000 }, { u: boss, c: 20000 }]);
  h.eq('staff only noticed', r5, { mode: 'everyone', held: 0, noticed: 2, logged: 2 });
  h.eq('moderator passes', await asUser(mod), null);
  h.eq('site admin passes', await asUser(boss), null);
  await h.admin();
  await h.db.query(`update public.feature_flags set users = array[$1::uuid] where key = 'request_limits'`, [amy]);

  // ---- expired rows let people through ----
  await h.db.query(`update public.request_throttle set until = now() - interval '1 minute' where user_id = $1`, [bob]);
  h.eq('expired hold passes', await asUser(bob), null);

  // ---- off: the guard ignores rows, the detector does nothing ----
  await h.db.exec(`update public.feature_flags set mode = 'off' where key = 'request_limits'`);
  h.eq('flag off: held row ignored', await asUser(amy), null);
  h.eq('flag off: apply does nothing', await apply([{ u: mod, c: 50000 }]), { mode: 'off', held: 0, noticed: 0, logged: 0 });
  await h.db.exec(`update public.feature_flags set mode = 'test' where key = 'request_limits'`);
  h.eq('back in test mode amy is held again', (await asUser(amy))?.code, 'PT429');

  // ---- site admins lift a hold, and it sticks for one window ----
  await h.as(bob);
  await h.fails('users cannot lift a hold', `select public.staff_clear_request_limit($1)`, [amy]);
  await h.as(mod);
  await h.fails('moderators cannot lift a hold', `select public.staff_clear_request_limit($1)`, [amy]);
  await h.as(boss);
  await h.ok('site admin lifts a hold', () => h.q(`select public.staff_clear_request_limit($1)`, [amy]));
  h.eq('lifted: amy passes', await asUser(amy), null);
  await h.admin();
  h.eq('lift logged', (await h.one(`select actor from public.mod_log where action = 'request_limit_cleared'`)).actor, boss);
  const r6 = await apply([{ u: amy, c: 9000 }]);
  h.eq('next run right after the Undo leaves amy alone', r6, { mode: 'test', held: 0, noticed: 0, logged: 0 });
  h.eq('still free after that run', await asUser(amy), null);
  await h.admin();
  await h.db.query(`update public.request_throttle set cleared_at = now() - interval '11 minutes' where user_id = $1`, [amy]);
  const r7 = await apply([{ u: amy, c: 9000 }]);
  h.eq('a window later she can be held again', r7, { mode: 'test', held: 1, noticed: 0, logged: 1 });
  h.eq('held again', (await asUser(amy))?.code, 'PT429');
  await h.admin();
  h.eq('cleared_at reset by the new hold', (await h.one(`select cleared_at from public.request_throttle where user_id = $1`, [amy])).cleared_at, null);

  // ---- old rows are cleaned up after a day ----
  await h.db.query(`update public.request_throttle set until = now() - interval '2 days' where user_id = $1`, [bob]);
  await apply([]);
  await h.db.exec(`update public.feature_flags set mode = 'test' where key = 'request_limits'`);
  await apply([{ u: cara, c: 7000 }]);
  await h.admin();
  h.eq('day-old row removed', (await h.one(`select count(*)::int n from public.request_throttle where user_id = $1`, [bob])).n, 0);

  // ---- the kick does nothing without its vault secret (no vault here: it must not be reached while off) ----
  await h.db.exec(`update public.feature_flags set mode = 'off' where key = 'request_limits'`);
  await h.ok('kick is a no-op while the flag is off', () => h.q(`select public.request_limits_kick()`));
}
