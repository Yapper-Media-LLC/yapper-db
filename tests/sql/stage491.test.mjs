// 491: Login with Yapper revocation can't lose a race with a code exchange (security pass 2, N4). Same base as 231
// (its stand-ins), then 231 and 491 (twice: re-runnable). PGlite is one connection, so the overlap is replayed as
// the state it used to leave behind (a token or code that slipped past oauth_revoke), and the shared grant lock is
// checked in pg_locks.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage231.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const h64 = (s) => createHash('sha256').update(s).digest('hex');

export default async function (h) {
  const M = mig('491_oauth_grant_lock.sql');
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (M.toLowerCase().includes(bad)) throw new Error(`491 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.db.exec(STANDINS);
  await h.db.exec(mig('231_oauth.sql'));
  await h.db.exec(M);
  await h.ok('491 re-runs cleanly', () => h.db.exec(M));

  const dev = await h.signup('dev@test.dev', 'dev');
  const amy = await h.signup('amy@test.dev', 'amy');
  await h.admin();
  await h.q(`update feature_flags set users = array[$1, $2]::uuid[] where key = 'oauth'`, [dev, amy]);
  const app = (await h.one(`select oauth_create_app($1, 'aal1', 'My Site', '', array['https://site.example/cb'], $2) r`, [dev, h64('s')])).r;

  const issue = (code) => h.q(`select oauth_issue_code($1, 'aal1', $2, 'https://site.example/cb', '{identify}', null, null, $3)`, [amy, app.id, h64(code)]);
  const exchange = async (code) =>
    (await h.one(`select oauth_exchange($1, $2, 'https://site.example/cb', null, true, $3) r`, [h64(code), app.id, h64('tok-' + code)])).r;
  const me = async (code) => (await h.one(`select oauth_me($1, '1.2.3.4') r`, [h64('tok-' + code)])).r;
  const revoke = async () => { await h.as(amy); const n = (await h.one(`select oauth_revoke($1) n`, [app.id])).n; await h.admin(); return n; };

  // Normal life still works.
  await issue('a1');
  h.eq('exchange works', (await exchange('a1')).scope, 'identify');
  h.eq('token works', (await me('a1')).username, 'amy');

  // Overlap 1: exchange ran while revoke was running, so its token was inserted after revoke's update looked.
  // Replay that leftover: revoke, then put the token back the way the race left it (not revoked).
  h.eq('revoke counts the token', await revoke(), 1);
  await h.q(`update oauth_tokens set revoked_at = null where token_hash = $1`, [h64('tok-a1')]);
  h.eq('a token made before the revocation never works, even unrevoked', (await me('a1')).error, 'invalid_token');
  h.eq('revocation recorded', (await h.one(`select count(*)::int n from oauth_revocations where user_id = $1 and app_id = $2`, [amy, app.id])).n, 1);

  // Overlap 2: a code minted while revoke ran (so revoke's "mark unused codes" missed it).
  await issue('a2');
  await h.q(`update oauth_codes set created_at = (select revoked_at from oauth_revocations where user_id = $1) - interval '1 second' where code_hash = $2`, [amy, h64('a2')]);
  const late = await exchange('a2');
  h.eq('a code from before the revocation is refused', [late.error, late.error_description], ['invalid_grant', 'Access to this app was removed']);
  h.eq('and no token was made from it', (await h.one(`select count(*)::int n from oauth_tokens where token_hash = $1`, [h64('tok-a2')])).n, 0);

  // A code that revoke did mark: refused as used.
  await issue('a3');
  await revoke();
  h.eq('a code revoke marked is refused', (await exchange('a3')).error, 'invalid_grant');

  // Signing in again after removing access works.
  await issue('a4');
  h.eq('fresh consent after a revoke works', (await exchange('a4')).scope, 'identify');
  h.eq('and its token works', (await me('a4')).username, 'amy');

  // Both sides take the same per-grant lock, so they run one after the other.
  const lockKey = (await h.one(`select hashtextextended('oauth-grant:' || $1::text || ':' || $2::text, 0) k`, [amy, app.id])).k;
  const held = async () => (await h.one(
    `select count(*)::int n from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()
       and ((classid::bigint << 32) | objid::bigint) = $1::bigint`, [lockKey])).n;
  await h.db.exec('begin');
  await h.as(amy);
  await h.q(`select oauth_revoke($1)`, [app.id]);
  await h.admin();
  h.eq('revoke holds the grant lock until commit', await held(), 1);
  await h.db.exec('commit');
  await issue('a5');
  await h.db.exec('begin');
  await exchange('a5');
  h.eq('exchange holds the same grant lock', await held(), 1);
  await h.db.exec('commit');
  h.eq('released after commit', await held(), 0);

  // Nobody else can touch it.
  await h.as(amy);
  await h.fails('users can\'t read revocations', `select * from oauth_revocations`);
  await h.fails('users can\'t take the grant lock directly', `select oauth_grant_lock($1, $2)`, [amy, app.id]);
  await h.fails('users can\'t call exchange', `select oauth_exchange($1, $2, 'x', null, true, $3)`, [h64('z'), app.id, h64('t')]);
  await h.admin();
}
