// 664: passkeys (flag passkeys). Both tables closed to clients; my_passkeys shows only your own, without keys;
// rename/remove only your own; challenges are single use, expire, and are bound to kind and owner; 10 per account;
// a duplicate credential is refused; the counter only moves forward and answers the owner; security_log rows (closed to
// clients) for add/rename/remove (the route logs logins), none in mod_log; old challenges get pruned.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['029_moderators.sql', '031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '664_passkeys.sql'), 'utf8');

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`664 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.ok('664 runs', () => h.db.exec(MIG));
  await h.ok('664 re-runs cleanly', () => h.db.exec(MIG));
  const flag = await h.one(`select mode, users, servers from feature_flags where key = 'passkeys'`);
  h.eq('flag in test', flag.mode, 'test');
  h.eq('flag users', flag.users, ['00000000-0000-4000-8000-00000000a001']);
  h.eq('flag servers', flag.servers, ['00000000-0000-4000-8000-00000000b001']);
  for (const t of ['user_passkeys', 'passkey_challenges', 'security_log']) {
    h.eq(`${t} has RLS`, (await h.one(`select relrowsecurity from pg_class where oid = 'public.${t}'::regclass`)).relrowsecurity, true);
  }

  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const a = await h.signup('pa@example.com', 'passa');
  const b = await h.signup('pb@example.com', 'passb');
  await h.admin();
  // a is a test user of the flag, b isn't (yet).
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'passkeys'`, [a]);
  h.eq('flag on for a', (await h.one(`select passkeys_on_for($1) v`, [a])).v, true);
  h.eq('flag off for b', (await h.one(`select passkeys_on_for($1) v`, [b])).v, false);

  const add = (u, cred, name = 'Phone') => h.q(
    `select passkey_add($1, $2, 'pubkeypubkeypubkey', 0, '{internal,hybrid}', 'yapin.gg', 'multiDevice', true, '', $3) id`, [u, cred, name]);
  const [{ id: k1 }] = await add(a, 'credential-aaaaaaaa-1', '  My  phone\u0007 ');
  h.eq('name cleaned', (await h.one(`select name from user_passkeys where id = $1`, [k1])).name, 'My  phone');
  h.eq('security_log row for add', (await h.one(`select count(*)::int n from security_log where event = 'passkey_added' and user_id = $1`, [a])).n, 1);
  h.eq('duplicate credential refused', await err(`select passkey_add($1, 'credential-aaaaaaaa-1', 'pubkeypubkeypubkey', 0, '{}', 'yapin.gg', 'x', false, '', 'x')`, [a]), 'Couldn\'t add that passkey. It may already be added.');
  h.eq('flag off: add refused', await err(`select passkey_add($1, 'credential-bbbbbbbb-1', 'pubkeypubkeypubkey', 0, '{}', 'yapin.gg', 'x', false, '', 'x')`, [b]), 'Passkeys aren\'t on for your account yet.');
  for (let i = 2; i <= 10; i++) await add(a, `credential-aaaaaaaa-${i}`);
  h.eq('11th refused', await err(`select passkey_add($1, 'credential-aaaaaaaa-11', 'pubkeypubkeypubkey', 0, '{}', 'yapin.gg', 'x', false, '', 'x')`, [a]), 'You can have up to 10 passkeys. Remove one first.');

  // Counter: forward only, compare-and-set; 0 -> 0 is fine (synced passkeys).
  h.eq('0 -> 0 ok, answers the owner', (await h.one(`select passkey_used($1, 0, 0) v`, [k1])).v, a);
  h.eq('0 -> 5 ok', (await h.one(`select passkey_used($1, 0, 5) v`, [k1])).v, a);
  h.eq('stale old value refused', (await h.one(`select passkey_used($1, 0, 9) v`, [k1])).v, null);
  h.eq('going back refused', (await h.one(`select passkey_used($1, 5, 3) v`, [k1])).v, null);
  h.eq('unknown id refused', (await h.one(`select passkey_used(gen_random_uuid(), 0, 0) v`)).v, null);
  h.eq('bad rp refused', await err(`select passkey_add($1, 'credential-aaaaaaaa-x', 'pubkeypubkeypubkey', 0, '{}', '', 'x', false, '', 'x')`, [a]), 'bad rp');
  h.eq('last_used set', !!(await h.one(`select last_used_at from user_passkeys where id = $1`, [k1])).last_used_at, true);

  // Challenges.
  h.eq('register needs a user', await err(`select passkey_challenge_new('register', null, 'yapin.gg', 'cccccccccccccccccccccc')`), 'bad challenge kind');
  h.eq('login takes no user', await err(`select passkey_challenge_new('login', $1, 'yapin.gg', 'cccccccccccccccccccccc')`, [a]), 'bad challenge kind');
  const { id: c1 } = await h.one(`select passkey_challenge_new('login', null, 'yapin.gg', 'challenge-one-0000000') id`);
  h.eq('wrong kind gets nothing', (await h.q(`select * from passkey_challenge_take($1, 'register', null)`, [c1])).length, 0);
  h.eq('taken once', await h.q(`select * from passkey_challenge_take($1, 'login', null)`, [c1]), [{ challenge: 'challenge-one-0000000', rp_id: 'yapin.gg' }]);
  h.eq('not twice', (await h.q(`select * from passkey_challenge_take($1, 'login', null)`, [c1])).length, 0);
  const { id: c2 } = await h.one(`select passkey_challenge_new('register', $1, 'yapin.gg', 'challenge-two-0000000') id`, [a]);
  h.eq('someone else can\'t take a register challenge', (await h.q(`select * from passkey_challenge_take($1, 'register', $2)`, [c2, b])).length, 0);
  h.eq('owner can', (await h.q(`select * from passkey_challenge_take($1, 'register', $2)`, [c2, a])).length, 1);
  const { id: c3 } = await h.one(`select passkey_challenge_new('login', null, 'yapin.gg', 'challenge-three-00000') id`);
  await h.q(`update passkey_challenges set expires_at = now() - interval '1 second' where id = $1`, [c3]);
  h.eq('expired gets nothing', (await h.q(`select * from passkey_challenge_take($1, 'login', null)`, [c3])).length, 0);
  await h.q(`update passkey_challenges set expires_at = now() - interval '2 hours' where id = $1`, [c3]);
  await h.q(`select passkey_challenge_new('login', null, 'yapin.gg', 'challenge-four-000000')`);
  h.eq('long-dead challenge pruned', (await h.one(`select count(*)::int n from passkey_challenges where id = $1`, [c3])).n, 0);
  h.eq('fresh ones kept', (await h.one(`select count(*)::int n from passkey_challenges where id = $1`, [c1])).n, 1);

  // As clients.
  const [{ id: kb }] = await (async () => {
    await h.q(`update feature_flags set users = users || $1::uuid where key = 'passkeys'`, [b]);
    return add(b, 'credential-bbbbbbbb-1', 'B key');
  })();
  for (const role of [null, a]) {
    await h.as(role);
    const who = role ? 'signed in' : 'anon';
    h.eq(`${who}: can't read user_passkeys`, (await err(`select * from user_passkeys`)).includes('permission denied'), true);
    // 660's definition: staff read it through a policy, everyone else gets nothing (anon: no grant at all).
    if (role) h.eq(`${who}: sees no security_log rows`, (await h.q(`select * from security_log`)).length, 0);
    else h.eq(`${who}: can't read security_log`, (await err(`select * from security_log`)).includes('permission denied'), true);
    h.eq(`${who}: can't write security_log`, (await err(`insert into security_log (user_id, event) values ($1, 'x')`, [a])).includes('permission denied'), true);
    h.eq(`${who}: can't read passkey_challenges`, (await err(`select * from passkey_challenges`)).includes('permission denied'), true);
    h.eq(`${who}: can't insert user_passkeys`, (await err(`insert into user_passkeys (user_id, credential_id, public_key, rp_id) values ($1, 'credential-xxxxxxxx-1', 'pubkeypubkeypubkey', 'yapin.gg')`, [a])).includes('permission denied'), true);
    for (const fn of [
      `passkey_add($1, 'credential-xxxxxxxx-2', 'pubkeypubkeypubkey', 0, '{}', 'yapin.gg', 'x', false, '', 'x')`,
      `passkey_challenge_new('login', null, 'yapin.gg', 'cccccccccccccccccccccc')`,
      `passkey_challenge_take('${c1}', 'login', null)`,
      `passkey_used('${k1}', 5, 6)`,
      `passkeys_on_for($1)`,
    ]) {
      const sql = `select ${fn}`;
      h.eq(`${who}: ${fn.split('(')[0]} refused`, (await err(sql, sql.includes('$1') ? [a] : [])).includes('permission denied'), true);
    }
  }
  await h.as(null);
  h.eq('anon: my_passkeys refused', (await err(`select * from my_passkeys()`)).includes('permission denied'), true);
  h.eq('anon: remove_passkey refused', (await err(`select remove_passkey($1)`, [k1])).includes('permission denied'), true);

  await h.as(a);
  const mine = await h.q(`select * from my_passkeys()`);
  h.eq('a sees 10', mine.length, 10);
  h.eq('no keys in the list', Object.keys(mine[0]).sort(), ['backed_up', 'created_at', 'device_type', 'id', 'last_used_at', 'name']);
  h.eq('a can\'t rename b\'s', await err(`select rename_passkey($1, 'mine now')`, [kb]), 'That passkey isn\'t there anymore.');
  h.eq('a can\'t remove b\'s', await err(`select remove_passkey($1)`, [kb]), 'That passkey isn\'t there anymore.');
  h.eq('empty name refused', await err(`select rename_passkey($1, '   ')`, [k1]), 'Give it a name');
  await h.q(`select rename_passkey($1, 'Laptop')`, [k1]);
  await h.q(`select rename_passkey($1, ' Laptop ')`, [k1]); // unchanged: no second log row
  await h.q(`select remove_passkey($1)`, [k1]);
  h.eq('a sees 9', (await h.q(`select * from my_passkeys()`)).length, 9);
  await h.as(b);
  h.eq('b sees only its own', (await h.q(`select name from my_passkeys()`)).map((r) => r.name), ['B key']);
  await h.admin();
  h.eq('b\'s still there', (await h.one(`select count(*)::int n from user_passkeys where id = $1`, [kb])).n, 1);
  h.eq('security_log rename + remove', (await h.q(`select event, detail from security_log where user_id = $1 and event in ('passkey_renamed', 'passkey_removed') order by id`, [a])),
    [{ event: 'passkey_renamed', detail: { to: 'Laptop', from: 'My  phone' } }, { event: 'passkey_removed', detail: { name: 'Laptop' } }]);
  h.eq('nothing in mod_log', (await h.one(`select count(*)::int n from mod_log where action like 'passkey%'`)).n, 0);
}
