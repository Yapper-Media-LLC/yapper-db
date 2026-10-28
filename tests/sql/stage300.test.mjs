// 300: reopen_verification. Staff can undo a mistaken rejection while the 7 day wait is still running.
// Starts from stage 24 with stand-ins for the live pieces the function calls. mod_guard is the live text
// (copied from stage242), so self / staff targets and the hourly limit are tested for real.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '300_reopen_verification.sql'), 'utf8');

const MOD_GUARD = String.raw`
create or replace function public.mod_guard(action text, target uuid, why text)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout', 'takedown', 'purge') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action
    when 'ban' then 40 when 'takedown' then 5 when 'purge' then 20 when 'timeout' then 60 when 'reset' then 20
    when 'unban' then 10 when 'badge' then 10 when 'untimeout' then 30 when 'verify' then 60
    when 'unwarn' then 30 when 'mark_bot' then 20 when 'server_hide' then 10 else 60 end;
  logged := case action
    when 'badge' then array['badge_given', 'badge_removed']
    when 'takedown' then array['server_takedown']
    when 'untimeout' then array['timeout_cleared']
    when 'verify' then array['verify', 'verify_reject', 'verify_ask_proof']
    when 'mark_bot' then array['marked_bot', 'unmarked_bot']
    when 'reset' then array['reset', 'profile_reset']
    else array[action] end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then
    raise exception 'You''ve hit the hourly limit for that (% an hour). Wait a bit or ask an admin to do it.', lim;
  end if;
end; $function$;
`;

/** The error message a statement throws, or '' if it worked. */
async function msg(h, sql, params = []) {
  try { await h.db.query(sql, params); return ''; } catch (e) { return String(e.message); }
}

export default async function (h) {
  await h.admin();
  await h.db.exec(`
    alter table public.profiles add column if not exists verified_as text;
    create table if not exists public.verification_requests (
      id uuid primary key default gen_random_uuid(), user_id uuid not null, platform text, handle text, link text, note text,
      proof_path text, status text not null default 'pending', reviewed_by uuid, reviewed_at timestamptz, review_note text,
      created_at timestamptz not null default now(), proof_added_at timestamptz, asked_at timestamptz);
    create table if not exists public.mod_log (
      id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid, message_id uuid, reason text,
      created_at timestamptz default now());
    create table if not exists public.staff_standin (user_id uuid primary key, role text not null);
    create table if not exists public.banned_standin (user_id uuid primary key);
    create table if not exists public.bc_calls (topic text, event text);
    create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid() and role = 'admin') $$;
    create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid() and role = 'mod') $$;
    create or replace function public.is_staff_user(u uuid) returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = u) $$;
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
      as $$ select public.is_site_admin() or public.is_site_mod() $$;
    create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.banned_standin where user_id = uid) $$;
    create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
      returns void language plpgsql security definer set search_path = public as $$ begin insert into public.bc_calls values (topic_name, event_name); end $$;
    grant select, insert on public.mod_log to authenticated;
  `);
  await h.db.exec(MOD_GUARD);
  await h.db.exec(MIG);
  await h.ok('300 re-runs cleanly', () => h.db.exec(MIG));

  const admin = await h.signup('admin@test.dev', 'admin');
  const mod = await h.signup('mod@test.dev', 'mod');
  const mod2 = await h.signup('mod2@test.dev', 'mod2');
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  await h.q(`insert into staff_standin values ($1, 'admin'), ($2, 'mod'), ($3, 'mod')`, [admin, mod, mod2]);

  // A rejection `ago` old (default 2 days: inside the 7 day wait), made by `mod`.
  const rej = async (uid, ago = '2 days', by = mod) => (await h.one(
    `insert into verification_requests (user_id, platform, handle, status, reviewed_by, reviewed_at, review_note, created_at)
     values ($1, 'youtube', 'amyplays', 'rejected', $2, now() - $3::interval, 'nope', now() - ($3::interval + interval '1 day')) returning id`,
    [uid, by, ago])).id;
  const status = async (id) => (await h.one(`select status from verification_requests where id = $1`, [id])).status;

  const r1 = await rej(amy);

  // Normal users can't, and a failed try changes nothing.
  await h.as(amy);
  h.eq('normal users can’t reopen', /Moderators only/.test(await msg(h, `select reopen_verification($1)`, [r1])), true);
  await h.admin();
  h.eq('a failed try leaves it rejected', await status(r1), 'rejected');

  // Happy path, by a different mod than the one who rejected. 60 reject/ask-proof rows must not use up the reopen limit.
  await h.q(`insert into mod_log (actor, action) select $1, 'verify_reject' from generate_series(1, 60)`, [mod2]);
  await h.as(mod2);
  h.eq('another mod can reopen it', await msg(h, `select reopen_verification($1, 'my bad')`, [r1]), '');
  await h.admin();
  const after = await h.one(`select status, reviewed_by, reviewed_at, review_note from verification_requests where id = $1`, [r1]);
  h.eq('goes back to pending', after.status, 'pending');
  h.eq('review fields are cleared', [after.reviewed_by, after.reviewed_at, after.review_note], [null, null, '']);
  const log = await h.one(`select actor, action, target_id, reason from mod_log where action = 'verify_reopen'`);
  h.eq('it is logged with who and why', [log.actor, log.target_id, log.reason], [mod2, amy, 'my bad (youtube amyplays)']);
  h.eq('the user is told live', (await h.one(`select count(*)::int as n from bc_calls where topic = $1 and event = 'verification'`, ['user:' + amy])).n, 1);

  // Wrong status.
  await h.as(mod2);
  h.eq('a pending request can’t be reopened', /Only rejected/.test(await msg(h, `select reopen_verification($1)`, [r1])), true);
  await h.admin();
  const appr = (await h.one(`insert into verification_requests (user_id, platform, handle, status, reviewed_at) values ($1, 'twitch', 'bobby', 'approved', now()) returning id`, [bob])).id;
  await h.as(mod2);
  h.eq('an approved request can’t be reopened', /Only rejected/.test(await msg(h, `select reopen_verification($1)`, [appr])), true);
  h.eq('unknown id', /Not found/.test(await msg(h, `select reopen_verification(gen_random_uuid())`)), true);

  // Old rejections, and legacy rows with no review time: they can apply again themselves.
  await h.admin();
  const old = await rej(cat, '8 days');
  const noTime = await rej(bob, '1 day');
  await h.q(`update verification_requests set reviewed_at = null where id = $1`, [noTime]);
  await h.as(mod2);
  h.eq('rejections older than 7 days stay rejected', /older than 7 days/.test(await msg(h, `select reopen_verification($1)`, [old])), true);
  h.eq('a rejection with no review time stays rejected', /older than 7 days/.test(await msg(h, `select reopen_verification($1)`, [noTime])), true);

  // Only the latest request, nothing else open, no badge, not banned.
  await h.admin();
  await h.q(`delete from verification_requests where user_id = $1`, [bob]);
  const first = await rej(bob, '3 days');
  const other = (await h.one(`insert into verification_requests (user_id, platform, handle, status, created_at) values ($1, 'x', 'bobx', 'needs_proof', now() - interval '10 days') returning id`, [bob])).id;
  await h.as(mod2);
  h.eq('not while they have a needs_proof request', /newer request/.test(await msg(h, `select reopen_verification($1)`, [first])), true);
  await h.admin();
  await h.q(`update verification_requests set status = 'pending' where id = $1`, [other]);
  await h.as(mod2);
  h.eq('not while they have a pending request', /newer request/.test(await msg(h, `select reopen_verification($1)`, [first])), true);
  await h.admin();
  await h.q(`update verification_requests set status = 'rejected', reviewed_at = now() - interval '1 day', created_at = now() - interval '1 day' where id = $1`, [other]);
  await h.as(mod2);
  h.eq('not when a newer request exists', /newer request/.test(await msg(h, `select reopen_verification($1)`, [first])), true);
  await h.admin();
  await h.q(`delete from verification_requests where id = $1`, [other]);
  await h.q(`update profiles set verified_as = 'YouTube · bobby' where id = $1`, [bob]);
  await h.as(mod2);
  h.eq('not when they already have the badge', /already verified/.test(await msg(h, `select reopen_verification($1)`, [first])), true);
  await h.admin();
  await h.q(`update profiles set verified_as = null where id = $1`, [bob]);
  await h.q(`insert into banned_standin values ($1)`, [bob]);
  await h.as(mod2);
  h.eq('not when the account is banned', /banned/.test(await msg(h, `select reopen_verification($1)`, [first])), true);
  await h.admin();
  await h.q(`delete from banned_standin where user_id = $1`, [bob]);
  h.eq('the failed tries left it rejected', await status(first), 'rejected');

  // mod_guard with the applicant as target: mods can't reopen for staff (including themselves). Admins can.
  const staffReq = await rej(mod, '1 day', admin);
  await h.as(mod);
  h.eq('a mod can’t reopen their own rejection', /moderate an admin or another moderator/.test(await msg(h, `select reopen_verification($1)`, [staffReq])), true);
  await h.admin();
  h.eq('it stayed rejected', await status(staffReq), 'rejected');
  await h.as(admin);
  h.eq('an admin can', await msg(h, `select reopen_verification($1)`, [staffReq]), '');
  await h.admin();
  h.eq('and it is pending now', await status(staffReq), 'pending');

  // Own hourly limit: reopens count against themselves (60), not against the verify limit.
  await h.q(`insert into mod_log (actor, action) select $1, 'verify_reopen' from generate_series(1, 59)`, [mod2]);
  await h.as(mod2);
  h.eq('the 61st reopen in an hour is refused', /hourly limit/.test(await msg(h, `select reopen_verification($1)`, [first])), true);
  await h.admin();
  h.eq('and nothing changed', await status(first), 'rejected');
  await h.as(admin);
  h.eq('admins have no limit', await msg(h, `select reopen_verification($1)`, [first]), '');

  // Grants.
  await h.admin();
  h.eq('anon has no execute', (await h.one(`select has_function_privilege('anon', 'public.reopen_verification(uuid, text)', 'execute') as ok`)).ok, false);
  h.eq('authenticated has execute', (await h.one(`select has_function_privilege('authenticated', 'public.reopen_verification(uuid, text)', 'execute') as ok`)).ok, true);
}
