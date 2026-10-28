// 584: head mods can unverify. Starts from stage 24 (profiles, site_admins from 019) plus the flags tables (031/041)
// and stand-ins for the later bits the function touches (verified_as from 037, site_moderators with head from 029/365,
// mod_log, is_site_mod, is_head_mod, staff_mfa_ok, is_staff_user, mod_guard).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '584_unverify_head_mods.sql'), 'utf8');

const STANDINS = `
alter table public.profiles add column if not exists verified_as text;
create table if not exists public.site_moderators (user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(), suspended_at timestamptz, head boolean not null default false);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid,
  message_id uuid, reason text not null default '', created_at timestamptz not null default now());
alter table public.mod_log enable row level security;
create or replace function public.staff_mfa_ok() returns boolean language sql stable as $$ select true $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) and public.staff_mfa_ok();
$$;
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null) and public.staff_mfa_ok();
$$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid and suspended_at is null);
$$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = mod_guard.action and created_at > now() - interval '1 hour';
  if n >= 60 then raise exception 'You''ve hit the hourly limit for that (60 an hour).'; end if;
end; $$;
insert into public.feature_flags (key, label, mode) values ('mod_verify', 'Mods can verify', 'off') on conflict (key) do nothing;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('584 re-runs cleanly', () => h.db.exec(MIG));

  const antic = await h.signup('antic584@test.dev', 'antic584');
  const head = await h.signup('head584@test.dev', 'head584');
  const paused = await h.signup('paused584@test.dev', 'paused584');
  const mod = await h.signup('mod584@test.dev', 'mod584');
  const plain = await h.signup('plain584@test.dev', 'plain584');
  const v1 = await h.signup('v1584@test.dev', 'v1584');
  const v2 = await h.signup('v2584@test.dev', 'v2584');
  const v3 = await h.signup('v3584@test.dev', 'v3584');
  const v4 = await h.signup('v4584@test.dev', 'v4584');
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, false)`, [head, mod]);
  await h.q(`insert into site_moderators (user_id, head, suspended_at) values ($1, true, now())`, [paused]);
  await h.q(`update profiles set verified_as = 'Instagram · test' where id = any($1::uuid[])`, [[v1, v2, v3, v4, head, mod]]);

  const verified = async (id) => { await h.admin(); return (await h.one(`select verified_as from profiles where id = $1`, [id])).verified_as; };
  const logged = async (actor, target) => { await h.admin(); return (await h.one(`select count(*)::int n from mod_log where actor = $1 and action = 'unverify' and target_id = $2`, [actor, target])).n; };

  // Normal user: refused.
  await h.as(plain);
  await h.fails('normal user cannot unverify', `select unverify($1, 'because')`, [v1]);
  await h.fails('normal user cannot unverify without a note either', `select unverify($1)`, [v1]);
  h.eq('v1 still verified', await verified(v1), 'Instagram · test');

  // Plain mod: refused while mod_verify is off; with the flag on they still need a reason (unchanged behaviour).
  await h.as(mod);
  await h.fails('plain mod cannot unverify (flag off)', `select unverify($1, 'a good reason')`, [v1]);
  h.eq('v1 still verified after the mod', await verified(v1), 'Instagram · test');
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'mod_verify'`);
  await h.as(mod);
  await h.fails('plain mod with the flag still needs a reason', `select unverify($1)`, [v1]);
  await h.fails('plain mod with the flag: short reason refused', `select unverify($1, 'abc')`, [v1]);
  await h.ok('plain mod with the flag and a reason can (as before)', () => h.q(`select unverify($1, 'bio no longer matches')`, [v4]));
  h.eq('v4 unverified by the mod', await verified(v4), null);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'mod_verify'`);

  // Paused head mod: refused.
  await h.as(paused);
  await h.fails('suspended head mod cannot unverify', `select unverify($1, 'reason here')`, [v1]);

  // Head mod: can, no reason needed, logged.
  await h.as(head);
  await h.ok('head mod can unverify without a note', () => h.q(`select unverify($1)`, [v1]));
  h.eq('v1 unverified', await verified(v1), null);
  h.eq('logged against the head mod', await logged(head, v1), 1);
  await h.as(head);
  await h.fails('head mod: already unverified is an error', `select unverify($1)`, [v1]);
  await h.fails('head mod cannot unverify a staff member', `select unverify($1)`, [mod]);
  await h.fails('head mod cannot unverify themself', `select unverify($1)`, [head]);
  h.eq('mod still verified', await verified(mod), 'Instagram · test');

  // Head mod hourly cap (mod_guard: 60 unverify rows in the last hour).
  await h.admin();
  await h.q(`insert into mod_log (actor, action, target_id, reason) select $1, 'unverify', $2, 'x' from generate_series(1, 60)`, [head, v1]);
  await h.as(head);
  await h.fails('head mod hits the hourly cap', `select unverify($1)`, [v2]);
  h.eq('v2 still verified after the cap', await verified(v2), 'Instagram · test');
  await h.admin();
  await h.q(`update mod_log set created_at = now() - interval '2 hours' where actor = $1`, [head]);
  await h.as(head);
  await h.ok('cap is per hour', () => h.q(`select unverify($1, 'note kept')`, [v2]));
  h.eq('v2 unverified once the hour passed', await verified(v2), null);
  h.eq('the note is logged', (await h.one(`select reason from mod_log where actor = $1 and target_id = $2 and created_at > now() - interval '1 minute'`, [head, v2])).reason, 'note kept');

  // Admin: unchanged, no reason, no cap, staff targets allowed.
  await h.as(antic);
  await h.ok('admin can unverify without a note', () => h.q(`select unverify($1)`, [v3]));
  h.eq('v3 unverified', await verified(v3), null);
  await h.as(antic);
  await h.ok('admin can unverify a moderator', () => h.q(`select unverify($1)`, [mod]));
  h.eq('mod unverified by the admin', await verified(mod), null);
  h.eq('admin rows logged', (await logged(antic, v3)) + (await logged(antic, mod)), 2);

  // Anonymous: no execute.
  await h.as(null);
  await h.fails('anon cannot call unverify', `select unverify($1)`, [head]);
}
