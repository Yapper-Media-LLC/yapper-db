// 589: staff applications. Starts from stage 24 (profiles, servers, server_members, site_admins from 019) plus the
// flags tables (031/041) and stand-ins for the later staff bits (site_moderators with head, site_managers,
// site_community_managers, site_bans, muted_until, mod_log, is_site_manager, is_head_mod, admin_set_moderator, bc_notice).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '589_staff_applications.sql'), 'utf8');

export const STANDINS = `
alter table public.profiles add column if not exists muted_until timestamptz;
create table if not exists public.site_moderators (user_id uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid, created_at timestamptz not null default now(), suspended_at timestamptz, suspended_reason text,
  head boolean not null default false);
create table if not exists public.site_managers (user_id uuid primary key);
create table if not exists public.site_community_managers (user_id uuid primary key);
create table if not exists public.site_bans (user_id uuid primary key);
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid,
  message_id uuid, reason text not null default '', created_at timestamptz not null default now());
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null);
$$;
create or replace function public.is_site_manager() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_managers m join public.site_moderators s on s.user_id = m.user_id
                  where m.user_id = auth.uid() and s.head and s.suspended_at is null);
$$;
-- Trimmed live body: who may add, then the insert and the log row.
create or replace function public.admin_set_moderator(uid uuid, on_off boolean, note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not (public.is_site_admin() or public.is_site_manager() or public.is_head_mod()) then raise exception 'Admins only'; end if;
  if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
  insert into public.site_moderators (user_id, added_by) values (uid, auth.uid()) on conflict (user_id) do nothing;
  get diagnostics n = row_count;
  if n > 0 then insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'mod_added', uid, left(note, 300)); end if;
end $$;
create table if not exists public.t589_notices (topic text, event text, payload jsonb);
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language sql as $$
  insert into public.t589_notices values (topic_name, event_name, payload);
$$;
`;

const WHY = 'I am on every day and I keep seeing spam slip through in the big servers.';

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('589 re-runs cleanly', () => h.db.exec(MIG));

  const antic = await h.signup('antic589@test.dev', 'antic589');
  const head = await h.signup('head589@test.dev', 'head589');
  const mod = await h.signup('mod589@test.dev', 'mod589');
  const ann = await h.signup('ann589@test.dev', 'ann589');
  const bob = await h.signup('bob589@test.dev', 'bob589');
  const kid = await h.signup('kid589@test.dev', 'kid589');
  const outsider = await h.signup('out589@test.dev', 'out589');
  const banned = await h.signup('ban589@test.dev', 'ban589');
  const muted = await h.signup('mute589@test.dev', 'mute589');
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, false)`, [head, mod]);
  await h.q(`update profiles set created_at = now() - interval '90 days' where id <> $1`, [kid]);
  await h.q(`insert into site_bans (user_id) values ($1)`, [banned]);
  await h.q(`update profiles set muted_until = now() + interval '1 hour' where id = $1`, [muted]);
  // The test server: flag servers list. Everyone but the outsider is in it.
  const SID = '00000000-0000-4000-8000-00000000b001';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Test', $2)`, [SID, antic]);
  await h.q(`insert into server_members (server_id, user_id) select $1, unnest($2::uuid[]) on conflict do nothing`,
    [SID, [antic, head, mod, ann, bob, kid, banned, muted]]);

  const info = async () => (await h.one(`select my_staff_application() j`)).j;
  const apply = (why = WHY, hours = 'CET, evenings', exp = '', agree = true) =>
    h.q(`select apply_for_staff($1, $2, $3, $4)`, [why, hours, exp, agree]);
  const app = async (uid) => { await h.admin(); return h.one(`select * from staff_applications where user_id = $1 order by created_at desc limit 1`, [uid]); };
  const isMod = async (uid) => { await h.admin(); return (await h.one(`select count(*)::int n from site_moderators where user_id = $1`, [uid])).n === 1; };

  // Flag: test mode reaches members of the test server, not outsiders.
  await h.as(outsider);
  h.eq('outsider: feature off', (await info()).on, false);
  await h.fails('outsider cannot apply', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  await h.as(ann);
  h.eq('test server member: feature on', (await info()).on, true);
  h.eq('ann may apply', (await info()).block, null);

  // Requirements.
  await h.as(kid);
  h.eq('new account is blocked', (await info()).block, 'Your account needs to be at least 30 days old to apply');
  await h.fails('new account cannot apply', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  await h.as(banned);
  await h.fails('banned cannot apply', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  await h.as(muted);
  await h.fails('timed out cannot apply', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  await h.as(mod);
  await h.fails('staff cannot apply', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);

  // Form checks.
  await h.as(ann);
  await h.fails('must agree to the rules', `select apply_for_staff($1, 'UTC', '', false)`, [WHY]);
  await h.fails('why too short', `select apply_for_staff('pls', 'UTC', '', true)`);
  await h.fails('hours needed', `select apply_for_staff($1, '  ', '', true)`, [WHY]);
  await h.fails('why too long', `select apply_for_staff($1, 'UTC', '', true)`, ['x'.repeat(1001)]);
  await h.ok('ann applies', () => apply());
  await h.as(ann);
  await h.fails('one waiting application at a time', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  h.eq('info shows pending', (await info()).app.status, 'pending');

  // Direct table access is closed.
  await h.as(ann);
  await h.fails('no direct select', `select * from staff_applications`);
  await h.fails('no direct update', `update staff_applications set status = 'accepted'`);

  // Reviewers.
  await h.as(mod);
  await h.fails('plain mod cannot list', `select * from staff_applications_list()`);
  await h.as(ann);
  await h.fails('applicant cannot list', `select * from staff_applications_list()`);
  const annApp = (await app(ann)).id;
  await h.as(ann);
  await h.fails('applicant cannot decide', `select decide_staff_application($1, true)`, [annApp]);
  await h.as(head);
  const list = await h.q(`select * from staff_applications_list()`);
  h.eq('head mod sees the waiting one', list.length, 1);
  await h.ok('head mod accepts', () => h.q(`select decide_staff_application($1, true, 'welcome!')`, [annApp]));
  h.eq('ann is a moderator', await isMod(ann), true);
  h.eq('accepted', (await app(ann)).status, 'accepted');
  h.eq('mod_added logged by the head mod',
    (await h.one(`select count(*)::int n from mod_log where actor = $1 and action = 'mod_added' and target_id = $2`, [head, ann])).n, 1);
  h.eq('ann got a live notice',
    (await h.one(`select count(*)::int n from t589_notices where topic = $1 and event = 'staff_application'`, ['user:' + ann])).n, 1);
  await h.as(head);
  await h.fails('cannot decide twice', `select decide_staff_application($1, false)`, [annApp]);

  // Next-start notice and ack.
  await h.as(ann);
  const dec = await h.one(`select * from my_staff_decision()`);
  h.eq('decision shows on next start', dec.status, 'accepted');
  await h.as(bob);
  await h.ok('others cannot ack it (no-op)', () => h.q(`select ack_staff_decision($1)`, [annApp]));
  await h.as(ann);
  await h.ok('ann acks', () => h.q(`select ack_staff_decision($1)`, [annApp]));
  h.eq('gone after ack', (await h.q(`select * from my_staff_decision()`)).length, 0);

  // Decline with a note, then the 30 day wait.
  await h.as(bob);
  await h.ok('bob applies', () => apply());
  const bobApp = (await app(bob)).id;
  await h.as(antic);
  await h.ok('admin declines with a note', () => h.q(`select decide_staff_application($1, false, 'not right now')`, [bobApp]));
  h.eq('bob not a mod', await isMod(bob), false);
  h.eq('decline logged', (await h.one(`select count(*)::int n from mod_log where actor = $1 and action = 'staff_app_declined' and target_id = $2`, [antic, bob])).n, 1);
  h.eq('note kept', (await app(bob)).note, 'not right now');
  await h.as(bob);
  h.eq('bob sees the note', (await h.one(`select * from my_staff_decision()`)).note, 'not right now');
  await h.fails('bob must wait 30 days', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  await h.admin();
  await h.q(`update staff_applications set decided_at = now() - interval '31 days' where id = $1`, [bobApp]);
  await h.as(bob);
  await h.ok('bob can apply after 30 days', () => apply());
  await h.as(bob);
  await h.ok('bob withdraws', () => h.q(`select withdraw_staff_application()`));
  h.eq('withdrawn', (await app(bob)).status, 'withdrawn');
  await h.as(bob);
  await h.fails('no instant reapply after withdrawing', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  h.eq('withdrawn is not a notice', (await h.q(`select * from my_staff_decision()`)).length, 0);

  // A reviewer cannot decide their own (an admin who applied is blocked earlier; simulate a pending row).
  await h.admin();
  await h.q(`insert into staff_applications (user_id, why, hours) values ($1, $2, 'UTC')`, [head, WHY]);
  const own = (await app(head)).id;
  await h.as(head);
  await h.fails('cannot decide your own', `select decide_staff_application($1, true)`, [own]);

  // Anonymous: no execute.
  await h.as(null);
  await h.fails('anon cannot apply', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  await h.fails('anon cannot list', `select * from staff_applications_list()`);
}
