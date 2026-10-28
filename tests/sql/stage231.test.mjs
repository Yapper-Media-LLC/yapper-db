// 231: Login with Yapper (OAuth2). PGlite can't replay every migration, so: 001..024, flags (031, 041), small
// stand-ins for the live pieces 231 calls (webhook_hit from 155, require_scanned_media, auth.mfa_factors,
// auth.jwt, profile columns), then 231 twice (re-runnable).
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable as $$ select false $$;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
create table if not exists auth.mfa_factors (id uuid primary key default gen_random_uuid(), user_id uuid, status text);
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
grant execute on function auth.jwt() to anon, authenticated;
create table if not exists public.webhook_rate (k text not null, bucket bigint not null, n int not null default 0,
  at timestamptz not null default now(), primary key (k, bucket));
create or replace function public.webhook_hit(k text, win int, lim int) returns numeric
language plpgsql security definer set search_path = public as $$
declare e numeric := extract(epoch from clock_timestamp()); b bigint := floor(e / win); got int;
begin
  insert into public.webhook_rate as r (k, bucket, n) values (k, b, 1)
    on conflict on constraint webhook_rate_pkey do update set n = r.n + 1 where r.n < lim
    returning r.n into got;
  if got is null then return greatest(0.001, round((b + 1) * win - e, 3)); end if;
  return 0;
end $$;
create table if not exists public.media_ok_paths (path text primary key);
create or replace function public.require_scanned_media() returns trigger language plpgsql security definer set search_path = public as $$
declare v text := to_jsonb(new) ->> tg_argv[0];
begin
  if v is not null and not exists (select 1 from public.media_ok_paths where path = v) then
    raise exception 'That image hasn''t been checked yet.';
  end if;
  return new;
end $$;
`;

const h64 = (s) => createHash('sha256').update(s).digest('hex');
const s256 = (v) => createHash('sha256').update(v).digest('base64url');

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '231_oauth.sql'), 'utf8');
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`231 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('231 re-runs cleanly', () => h.db.exec(MIG));

  const dev = await h.signup('dev@test.dev', 'dev');
  const amy = await h.signup('amy@test.dev', 'amy');
  const eve = await h.signup('eve@test.dev', 'eve');

  await h.admin();
  h.eq('flag exists in test mode', (await h.one(`select mode from feature_flags where key = 'oauth'`)).mode, 'test');

  const create = (owner, name, uris, secret = 's1') =>
    h.one(`select oauth_create_app($1, 'aal1', $2, '', $3::text[], $4) r`, [owner, name, uris, h64(secret)]);

  await h.fails('no app while the flag is off for me', `select oauth_create_app($1, 'aal1', 'My Site', '', '{}', $2)`, [dev, h64('x')]);
  await h.q(`update feature_flags set users = array[$1]::uuid[] where key = 'oauth'`, [dev]);

  for (const u of ['http://example.com/cb', 'https://example.com/#x', 'https://me@example.com/cb', 'javascript:alert(1)',
    'https://example.com/a b', 'http://localhost.evil.com/cb', 'https://exämple.com/', 'https://example.com\\@evil.com']) {
    await h.fails(`redirect refused: ${u}`, `select oauth_create_app($1, 'aal1', 'Site', '', array[$2], $3)`, [dev, u, h64('x')]);
  }
  await h.fails('more than 10 redirect URLs', `select oauth_create_app($1, 'aal1', 'Site', '', $2::text[], $3)`,
    [dev, Array.from({ length: 11 }, (_, i) => `https://e.com/${i}`), h64('x')]);
  await h.fails('name too short', `select oauth_create_app($1, 'aal1', 'x', '', '{}', $2)`, [dev, h64('x')]);

  const app = (await create(dev, 'My Site', ['https://site.example/cb', 'http://localhost:3000/cb', 'http://127.0.0.1/cb', ' https://site.example/cb '])).r;
  h.eq('app made, redirect URLs trimmed and de-duplicated', app.redirect_uris, ['https://site.example/cb', 'http://localhost:3000/cb', 'http://127.0.0.1/cb']);
  h.eq('no secret hash in what the owner gets', 'secret_hash' in app, false);
  for (let i = 0; i < 9; i++) await create(dev, `App ${i}`, []);
  await h.fails('11th app refused', `select oauth_create_app($1, 'aal1', 'One more', '', '{}', $2)`, [dev, h64('x')]);

  // ---- No direct access ----
  for (const who of [amy, null]) {
    await h.as(who);
    for (const t of ['oauth_apps', 'oauth_codes', 'oauth_tokens']) await h.fails(`${who ? 'users' : 'anon'} can't read ${t}`, `select * from ${t}`);
    await h.fails('no create from the client', `select oauth_create_app($1, 'aal1', 'Mine', '', '{}', $2)`, [amy, h64('x')]);
    await h.fails('no code minting from the client', `select oauth_issue_code($1, 'aal2', $2, 'https://site.example/cb', '{identify}', null, null, $3)`, [amy, app.id, h64('c')]);
    await h.fails('no exchange from the client', `select oauth_exchange($1, $2, 'x', null, true, $3)`, [h64('c'), app.id, h64('t')]);
    await h.fails('no me from the client', `select oauth_me($1, '1.2.3.4')`, [h64('t')]);
    await h.fails('no secret reset from the client', `select oauth_reset_secret($1, 'aal2', $2, $3)`, [dev, app.id, h64('y')]);
  }
  await h.as(null);
  await h.fails('anon has no apps list', `select oauth_my_apps()`);

  // ---- Consent page ----
  const info = (await h.one(`select oauth_app_info($1, 'https://site.example/cb') r`, [app.id])).r;
  h.eq('app info for the consent page (logged out too)', [info.name, info.owner_username, info.redirect_ok], ['My Site', 'dev', true]);
  h.eq('redirect must match exactly', (await h.one(`select oauth_app_info($1, 'https://site.example/cb/') r`, [app.id])).r.redirect_ok, false);
  h.eq('unknown client is null', (await h.one(`select oauth_app_info('not-a-uuid', 'x') r`)).r, null);

  // ---- Codes ----
  await h.admin();
  const issue = (user, code, { uri = 'https://site.example/cb', scope = ['identify'], ch = null, m = null, aal = 'aal1', client = app.id } = {}) =>
    h.q(`select oauth_issue_code($1, $2, $3, $4, $5::text[], $6, $7, $8)`, [user, aal, client, uri, scope, ch, m, h64(code)]);
  // While in test, only the test group can authorize (so they also see Authorized Apps to take it back).
  await h.fails('no authorizing while the flag is off for me', `select oauth_issue_code($1, 'aal1', $2, 'https://site.example/cb', '{identify}', null, null, $3)`, [amy, app.id, h64('flagoff')]);
  await h.q(`update feature_flags set users = array[$1, $2, $3]::uuid[] where key = 'oauth'`, [dev, amy, eve]);
  const tryIssue = (name, ...a) => h.ok(name, async () => {
    let threw = false;
    try { await issue(...a); } catch { threw = true; }
    if (!threw) throw new Error('expected an error');
  });
  await tryIssue('unregistered redirect refused', amy, 'c0', { uri: 'https://evil.example/cb' });
  await tryIssue('unknown scope refused', amy, 'c0', { scope: ['identify', 'email'] });
  await tryIssue('empty scope refused', amy, 'c0', { scope: [] });
  await tryIssue('plain PKCE refused', amy, 'c0', { ch: s256('v'.repeat(43)), m: 'plain' });
  await tryIssue('method without a challenge refused', amy, 'c0', { m: 'S256' });

  const exchange = async (code, { client = app.id, uri = 'https://site.example/cb', ch = null, conf = true, tok = 'tok-' + code } = {}) =>
    (await h.one(`select oauth_exchange($1, $2, $3, $4, $5, $6) r`, [h64(code), client, uri, ch, conf, h64(tok)])).r;

  await issue(amy, 'c1');
  h.eq('wrong client', (await exchange('c1', { client: '00000000-0000-0000-0000-000000000000' })).error, 'invalid_grant');
  h.eq('missing client', (await exchange('c1', { client: null })).error, 'invalid_grant');
  h.eq('wrong redirect_uri', (await exchange('c1', { uri: 'http://localhost:3000/cb' })).error, 'invalid_grant');
  h.eq('public client needs PKCE', (await exchange('c1', { conf: false })).error, 'invalid_grant');
  h.eq('verifier sent for a non-PKCE code', (await exchange('c1', { ch: s256('x'.repeat(43)) })).error, 'invalid_grant');
  const ok = await exchange('c1');
  h.eq('confidential swap works', ok, { scope: 'identify', expires_in: 2592000 });
  const me = (await h.one(`select oauth_me($1, '1.2.3.4') r`, [h64('tok-c1')])).r;
  h.eq('me shows the user', [me.id, me.username], [amy, 'amy']);
  h.eq('replayed code refused', (await exchange('c1', { tok: 'tok-c1b' })).error, 'invalid_grant');
  h.eq('replay revokes the token made from it', (await h.one(`select oauth_me($1, '1.2.3.4') r`, [h64('tok-c1')])).r.error, 'invalid_token');

  await issue(amy, 'c2');
  await h.q(`update oauth_codes set expires_at = now() - interval '1 second' where code_hash = $1`, [h64('c2')]);
  h.eq('expired code refused', (await exchange('c2')).error, 'invalid_grant');

  const verifier = 'abcdefghijklmnopqrstuvwxyz0123456789-._~ABCDEFG';
  await issue(amy, 'c3', { ch: s256(verifier), m: 'S256' });
  h.eq('wrong verifier refused', (await exchange('c3', { conf: false, ch: s256('nope'.repeat(11)) })).error, 'invalid_grant');
  h.eq('missing verifier refused', (await exchange('c3', { conf: true })).error, 'invalid_grant');
  h.eq('public client with PKCE works', (await exchange('c3', { conf: false, ch: s256(verifier) })).scope, 'identify');

  // ---- Token use ----
  await h.q(`update oauth_tokens set last_used_at = null`);
  await h.q(`select oauth_me($1, '1.2.3.4')`, [h64('tok-c3')]);
  const t1 = (await h.one(`select last_used_at from oauth_tokens where token_hash = $1`, [h64('tok-c3')])).last_used_at;
  h.eq('last_used_at set', !!t1, true);
  await h.q(`update oauth_tokens set expires_at = now() - interval '1 second' where token_hash = $1`, [h64('tok-c3')]);
  h.eq('expired token refused', (await h.one(`select oauth_me($1, '1.2.3.4') r`, [h64('tok-c3')])).r.error, 'invalid_token');
  await h.q(`update oauth_tokens set expires_at = now() + interval '30 days' where token_hash = $1`, [h64('tok-c3')]);

  // ---- Authorized Apps ----
  await h.as(amy);
  const grants = (await h.one(`select oauth_my_grants() r`)).r;
  h.eq('my grants list the app', [grants.length, grants[0].name, grants[0].scope], [1, 'My Site', ['identify']]);
  await h.as(eve);
  h.eq('others see no grants of mine', (await h.one(`select oauth_my_grants() r`)).r, []);
  h.eq('others can\'t revoke mine', (await h.one(`select oauth_revoke($1) n`, [app.id])).n, 0);
  await h.as(amy);
  h.eq('revoke', (await h.one(`select oauth_revoke($1) n`, [app.id])).n, 1);
  h.eq('nothing left', (await h.one(`select oauth_my_grants() r`)).r, []);
  await h.admin();
  h.eq('revoked token stops working', (await h.one(`select oauth_me($1, '1.2.3.4') r`, [h64('tok-c3')])).r.error, 'invalid_token');

  // ---- 2FA ----
  await h.q(`insert into auth.mfa_factors (user_id, status) values ($1, 'verified')`, [amy]);
  await tryIssue('2FA account needs aal2', amy, 'c4');
  await h.ok('aal2 works', () => issue(amy, 'c4', { aal: 'aal2' }));

  // ---- Bans ----
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'spam')`, [eve]);
  await tryIssue('banned people can\'t authorize', eve, 'c5');

  // ---- Owners ----
  await h.as(eve);
  await h.fails('not my app', `select oauth_update_app($1, 'Stolen')`, [app.id]);
  await h.fails('can\'t remove someone else\'s app', `select oauth_remove_app($1)`, [app.id]);
  await h.as(dev);
  h.eq('my apps', (await h.one(`select jsonb_array_length(oauth_my_apps()) n`)).n, 10);
  const up = (await h.one(`select oauth_update_app($1, 'Renamed', 'Hi', array['https://new.example/cb']) r`, [app.id])).r;
  h.eq('owner edits name and redirect URLs', [up.name, up.redirect_uris], ['Renamed', ['https://new.example/cb']]);
  await h.fails('icon from someone else\'s folder', `select oauth_update_app($1, null, null, null, $2)`, [app.id, `${amy}/x.png`]);
  await h.fails('unchecked icon', `select oauth_update_app($1, null, null, null, $2)`, [app.id, `${dev}/x.png`]);
  await h.admin();
  await h.q(`insert into media_ok_paths values ($1)`, [`${dev}/x.png`]);
  await h.as(dev);
  h.eq('checked icon in my folder', (await h.one(`select oauth_update_app($1, null, null, null, $2) r`, [app.id, `${dev}/x.png`])).r.icon_path, `${dev}/x.png`);
  h.eq('icon off', (await h.one(`select oauth_update_app($1, null, null, null, '') r`, [app.id])).r.icon_path, null);
  await h.admin();
  await h.ok('secret reset', () => h.q(`select oauth_reset_secret($1, 'aal1', $2, $3)`, [dev, app.id, h64('s2')]));
  await h.fails('secret reset by someone else', `select oauth_reset_secret($1, 'aal1', $2, $3)`, [amy, app.id, h64('s3')]);
  await h.as(dev);
  await h.ok('remove app', () => h.q(`select oauth_remove_app($1)`, [app.id]));
  await h.admin();
  h.eq('its codes and tokens are gone', (await h.one(`select ((select count(*) from oauth_tokens where app_id = $1) + (select count(*) from oauth_codes where app_id = $1))::int n`, [app.id])).n, 0);
}
