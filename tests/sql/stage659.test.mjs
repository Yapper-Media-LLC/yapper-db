// 659: Google sign-in guards. signup_route_guard only lets a route's note make a provider-email account;
// google_identity_guard keeps a Google login off password accounts whose email was never proven, and off our domains.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '659_google_login.sql'), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`659 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(`
    alter table auth.users add column if not exists raw_app_meta_data jsonb not null default '{}',
      add column if not exists encrypted_password text, add column if not exists email_confirmed_at timestamptz;
    create table auth.identities (id uuid primary key default gen_random_uuid(), user_id uuid not null, provider text not null, identity_data jsonb not null default '{}');
    create table public.pending_signups (email text primary key, created_at timestamptz not null default now());
    create table public.pending_bot_emails (email text primary key, created_at timestamptz not null default now());`);
  await h.ok('659 runs', () => h.db.exec(MIG));
  await h.ok('659 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`create or replace trigger signup_route_guard before insert on auth.users for each row execute function public.signup_route_guard();`);
  h.eq('flag in test', (await h.one(`select mode from feature_flags where key = 'google_login'`)).mode, 'test');
  await h.q(`insert into feature_flags (key, label, mode) values ('signup_route_only', 'x', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const mk = (email, app) => err(`insert into auth.users (email, raw_app_meta_data, raw_user_meta_data) values ($1, $2::jsonb, '{"username":"someone_new"}')`, [email, JSON.stringify(app)]);

  // signup_route_guard
  h.eq('no note: refused', await mk('a@test.dev', {}), 'Sign up on yapper.website.');
  await h.q(`insert into pending_signups (email) values ('b@test.dev')`);
  h.eq('Google login racing the note: refused', await mk('b@test.dev', { provider: 'google' }), 'Sign up on yapper.website.');
  h.eq('note kept for the route', (await h.one(`select count(*)::int n from pending_signups where email = 'b@test.dev'`)).n, 1);
  h.eq('route insert (provider email): ok', await mk('b@test.dev', { provider: 'email' }), 'ok');
  h.eq('note used up', (await h.one(`select count(*)::int n from pending_signups where email = 'b@test.dev'`)).n, 0);
  await h.q(`insert into pending_signups (email) values ('c@test.dev')`);
  h.eq('route insert without provider yet: ok', await mk('c@test.dev', {}), 'ok');
  await h.q(`insert into pending_bot_emails (email) values ('bot@test.dev')`);
  h.eq('bot emails unchanged', await mk('bot@test.dev', {}), 'ok');
  await h.q(`update feature_flags set mode = 'off' where key = 'signup_route_only'`);

  // google_identity_guard
  const user = async (email, pw, confirmed, app = {}) => (await h.one(
    `insert into auth.users (email, encrypted_password, email_confirmed_at, raw_app_meta_data) values ($1, $2, $3, $4::jsonb) returning id`,
    [email, pw, confirmed ? new Date().toISOString() : null, JSON.stringify(app)])).id;
  const link = (uid, email, provider = 'google') => err(`insert into auth.identities (user_id, provider, identity_data) values ($1, $2, $3::jsonb)`, [uid, provider, JSON.stringify({ email })]);
  const confirmedPw = await user('real@gmail.com', 'hash', true);
  const squatted = await user('victim@gmail.com', 'hash', false);
  const instant = await user('busy@gmail.com', 'hash', true, { instant: true });
  const googleMade = await user('g@gmail.com', null, true, { signup: 'google' });
  const staff = await user('bot@yapper.website', null, true);
  h.eq('confirmed password account links', await link(confirmedPw, 'real@gmail.com'), 'ok');
  h.eq('second Google identity on it is fine', await link(confirmedPw, 'real@gmail.com'), 'ok');
  h.eq('unconfirmed password account refused', await link(squatted, 'victim@gmail.com'), 'Log in with your password first (or reset it), then you can use Google.');
  h.eq('busy-path account refused', await link(instant, 'busy@gmail.com'), 'Log in with your password first (or reset it), then you can use Google.');
  h.eq('Google-made account links', await link(googleMade, 'g@gmail.com'), 'ok');
  h.eq('our domains refused', await link(staff, 'bot@yapper.website'), 'Google sign-in isn\'t for Yapin\' addresses.');
  h.eq('other providers untouched', await link(squatted, 'victim@gmail.com', 'email'), 'ok');
}
