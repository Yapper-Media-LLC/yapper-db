// 522: site moderators can approve verifications and take the verified badge off (flag mod_verify, per user).
// Starts from stage 24 with stand-ins for the live pieces (as in 479); mod_guard is the live body from Oct 25.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '522_mod_verify.sql'), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists verified_as text;
create table if not exists public.verification_requests (
  id uuid primary key default gen_random_uuid(), user_id uuid not null, platform text, handle text, link text, note text,
  proof_path text, status text not null default 'pending', reviewed_by uuid, reviewed_at timestamptz, review_note text not null default '',
  created_at timestamptz default now());
create table if not exists public.site_admins (user_id uuid primary key);
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.signup_log (id bigint generated always as identity primary key, ip text, created_at timestamptz not null default now());
alter table public.signup_log add column if not exists user_id uuid;
create table if not exists public.login_attempts (id bigint generated always as identity primary key, ip text not null, username text not null, ok boolean not null, at timestamptz not null default now());
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$ select public.is_site_admin() or public.is_site_mod() $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid) $$;
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $f$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  lim := case action when 'badge' then 10 when 'verify' then 60 else 60 end;
  logged := case action when 'verify' then array['verify', 'verify_reject', 'verify_ask_proof'] else array[action] end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then raise exception 'You''ve hit the hourly limit for that (% an hour). Wait a bit or ask an admin to do it.', lim; end if;
end; $f$;
create or replace function public.bc(topic text, ev text, op text, tbl text, sch text, n text, o text) returns void language sql as $$ select $$;
create or replace function public.skeleton(t text) returns text language sql immutable as $$ select lower(coalesce(t, '')) $$;
create or replace function public.name_key(t text) returns text language sql immutable as $$ select regexp_replace(translate(lower(coalesce(t, '')), '01i345780@$', 'olleastbooas'), '[^a-z0-9]', '', 'g') $$;
create or replace function public.verify_name_key(t text) returns text language sql immutable set search_path = public as $$
  select regexp_replace(public.skeleton(regexp_replace(normalize(regexp_replace(coalesce(t, ''), '^\\s*@+', ''), NFKD), '[\\u0300-\\u036f]', '', 'g')), '[^a-z0-9]', '', 'g') $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`522 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('522 runs', () => h.db.exec(MIG));
  await h.ok('522 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'mod_verify'`)).mode, 'test');

  const admin = await h.signup('admin@test.dev', 'boss');
  const mod = await h.signup('mod@test.dev', 'modder');
  const mod2 = await h.signup('mod2@test.dev', 'othermod');
  const a = await h.signup('a@test.dev', 'chan_a');
  const b = await h.signup('b@test.dev', 'chan_b');
  const alt = await h.signup('alt@test.dev', 'chan_alt');
  const pal = await h.signup('pal@test.dev', 'chan_pal');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2)`, [mod, mod2]);
  const req = async (uid, handle) => (await h.one(`insert into verification_requests (user_id, platform, handle, link) values ($1, 'youtube', $2, 'https://youtube.com/@x') returning id`, [uid, handle])).id;
  const ra = await req(a, 'chan_a');
  const rb = await req(b, 'chan_b');
  const ralt = await req(alt, 'chan_alt');
  const rmod2 = await req(mod2, 'othermod');
  const rself = await req(mod, 'modder');
  const rpal = await req(pal, 'chan_pal');
  // The mod and chan_alt signed in from the same network; chan_a only from its own (and signed up on another).
  // chan_pal signed up from the network the other moderator signed up on.
  await h.q(`insert into login_attempts (ip, username, ok) values ('1.1.1.1', 'modder', true), ('1.1.1.1', 'chan_alt', true), ('2.2.2.2', 'chan_a', true), ('1.1.1.1', 'chan_b', false)`);
  await h.q(`insert into signup_log (ip, user_id) values ('3.3.3.3', $1), ('3.3.3.3', $2), ('4.4.4.4', $3)`, [mod2, pal, a]);
  const verified = async (uid) => (await h.one(`select verified_as v from profiles where id = $1`, [uid])).v;
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);

  // Flag off for the mod: same as before.
  await h.as(mod);
  h.eq('flag off: mods still cannot approve', await err(`select review_verification($1, true)`, [ra]),
    'Only admins can approve verifications. Ask for proof or leave it for an admin.');
  h.eq('flag off: mods still cannot unverify', await err(`select unverify($1, 'fake channel')`, [a]), 'Admins only');
  await h.ok('flag off: mods can still reject', () => h.q(`select review_verification($1, false, 'no')`, [rb]));

  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'mod_verify'`, [mod]);

  await h.as(mod);
  await h.ok('flag on: mod approves', () => h.q(`select review_verification($1, true)`, [ra]));
  await h.admin();
  h.eq('approved account is verified', await verified(a), 'YouTube · chan_a');
  const log = await h.one(`select actor, action, target_id from mod_log where action = 'verify' order by id desc limit 1`);
  h.eq('approve is logged with the mod as actor', [log.actor, log.target_id], [mod, a]);
  h.eq('request marks the mod as reviewer', (await h.one(`select reviewed_by from verification_requests where id = $1`, [ra])).reviewed_by, mod);

  await h.as(mod);
  h.eq('own request still refused', await err(`select review_verification($1, true)`, [rself]),
    'You can\'t review your own verification. Ask another moderator.');
  h.eq('another moderator\'s request refused', await err(`select review_verification($1, true)`, [rmod2]),
    'You can\'t moderate an admin or another moderator');
  h.eq('same sign-in network as the mod (likely alt) refused', await err(`select review_verification($1, true)`, [ralt]),
    'This account shares a network with a staff account. Leave it for an admin.');
  h.eq('signed up on another mod\'s network refused', await err(`select review_verification($1, true)`, [rpal]),
    'This account shares a network with a staff account. Leave it for an admin.');
  await h.admin();
  h.eq('alt not verified', await verified(alt), null);
  h.eq('alt request still open', (await h.one(`select status from verification_requests where id = $1`, [ralt])).status, 'pending');
  h.eq('a failed login on that network does not count', (await h.one(`select count(*)::int n from login_attempts where username = 'chan_b' and ok`)).n, 0);

  // Admins are unchanged: the alt check is for moderators only, and admins can verify staff.
  await h.as(admin);
  await h.ok('admin approves the account the mod could not', () => h.q(`select review_verification($1, true)`, [ralt]));
  await h.ok('admin approves a moderator', () => h.q(`select review_verification($1, true)`, [rmod2]));

  // unverify by a mod: needs a reason, not on staff, logged.
  await h.as(mod);
  h.eq('mod unverify needs a reason', await err(`select unverify($1, 'no')`, [a]), 'Give a reason (at least 5 characters)');
  h.eq('mod cannot unverify another moderator', await err(`select unverify($1, 'fake channel')`, [mod2]), 'You can\'t moderate an admin or another moderator');
  await h.ok('mod unverifies with a reason', () => h.q(`select unverify($1, 'channel was sold')`, [a]));
  await h.admin();
  h.eq('badge is gone', await verified(a), null);
  const ulog = await h.one(`select actor, reason from mod_log where action = 'unverify' order by id desc limit 1`);
  h.eq('unverify is logged with the reason', [ulog.actor, ulog.reason], [mod, 'channel was sold']);
  await h.as(mod);
  h.eq('unverify on someone not verified says so', await err(`select unverify($1, 'channel was sold')`, [a]), 'They aren\'t verified');
  h.eq('nothing extra logged', (await h.one(`select count(*)::int n from mod_log where action = 'unverify'`)).n, 1);

  // Admin unverify still works with no reason, on staff too.
  await h.as(admin);
  await h.ok('admin unverifies a moderator without a reason', () => h.q(`select unverify($1)`, [mod2]));

  // Hourly cap for mods.
  await h.admin();
  await h.q(`insert into mod_log (actor, action, target_id) select $1, 'unverify', $2 from generate_series(1, 60)`, [mod, b]);
  await h.q(`update profiles set verified_as = 'YouTube · chan_alt' where id = $1`, [alt]);
  await h.as(mod);
  h.eq('mod hits the hourly limit', await err(`select unverify($1, 'channel was sold')`, [alt]),
    'You\'ve hit the hourly limit for that (60 an hour). Wait a bit or ask an admin to do it.');

  // Suspended mods, plain users and anon get nothing.
  await h.admin();
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [mod]);
  await h.as(mod);
  await h.fails('suspended mod cannot unverify', `select unverify($1, 'channel was sold')`, [alt]);
  await h.as(b);
  await h.fails('plain user cannot approve', `select review_verification($1, true)`, [rself]);
  await h.fails('plain user cannot unverify', `select unverify($1, 'channel was sold')`, [alt]);
  await h.as(null);
  await h.fails('anon cannot unverify', `select unverify($1, 'channel was sold')`, [alt]);
}
