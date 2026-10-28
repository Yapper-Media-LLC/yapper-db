// 579: mod action burst alerts. Starts from stage 24 plus the flags tables (031/041) and stand-ins for the later bits
// the migration touches (site_moderators with head, mod_log, is_head_mod, staff_mfa_ok, bc_notice).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '579_mod_burst_alerts.sql'), 'utf8');

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid, created_at timestamptz not null default now(), suspended_at timestamptz, suspended_reason text, head boolean not null default false);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null, target_id uuid,
  message_id uuid, reason text not null default '', created_at timestamptz not null default now());
alter table public.mod_log enable row level security;
create index if not exists mod_log_actor_idx on public.mod_log (actor, created_at desc);
create policy "admins read the mod log" on public.mod_log for select to authenticated using (public.is_site_admin() or actor = auth.uid());
grant select on public.mod_log to authenticated;
create or replace function public.staff_mfa_ok() returns boolean language sql stable as $$ select true $$;
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null) and public.staff_mfa_ok();
$$;
create table if not exists public.t579_notices (topic text, event text, payload jsonb);
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language sql as $$
  insert into public.t579_notices values (topic_name, event_name, payload);
$$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('579 re-runs cleanly', () => h.db.exec(MIG));

  const antic = await h.signup('antic579@test.dev', 'antic579');
  const head = await h.signup('head579@test.dev', 'head579');
  const head2 = await h.signup('head2579@test.dev', 'head2579');
  const paused = await h.signup('paused579@test.dev', 'paused579');
  const mod = await h.signup('mod579@test.dev', 'mod579');
  const plain = await h.signup('plain579@test.dev', 'plain579');
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, true), ($3, false)`, [head, head2, mod]);
  await h.q(`insert into site_moderators (user_id, head, suspended_at) values ($1, true, now())`, [paused]);
  // Flag on for Antic and both head mods (test mode).
  await h.q(`update feature_flags set users = array[$1::uuid, $2::uuid, $3::uuid] where key = 'mod_burst_alerts'`, [antic, head, head2]);

  const log = (actor, action, n = 1, ago = '0 seconds') =>
    h.q(`insert into mod_log (actor, action, target_id, reason, created_at)
         select $1, $2, $3, 'test', now() - $5::interval - (g || ' milliseconds')::interval from generate_series(1, $4::int) g`, [actor, action, plain, n, ago]);
  const alerts = () => h.q(`select actor, kind, action_count, actions, cardinality(log_ids) links, dismissed_at from mod_burst_alerts order by created_at`);
  const notices = () => h.q(`select topic, event, payload from t579_notices order by ctid`);
  const clear = async () => { await h.q(`delete from mod_burst_alerts`); await h.q(`delete from t579_notices`); await h.q(`delete from mod_log`); };

  h.eq('flag row (test)', (await h.one(`select mode from feature_flags where key = 'mod_burst_alerts'`)).mode, 'test');
  h.eq('two rules seeded', (await h.one(`select count(*)::int n from mod_burst_rules`)).n, 2);
  h.eq('actions rule: 10 in 10 min', (await h.one(`select threshold, window_minutes from mod_burst_rules where kind = 'actions'`)), { threshold: 10, window_minutes: 10 });

  // Under the threshold: nothing.
  await log(mod, 'ban', 9);
  h.eq('9 bans: no alert', (await alerts()).length, 0);
  h.eq('9 bans: no notice', (await notices()).length, 0);

  // The 10th ban trips it.
  await log(mod, 'ban', 1);
  let a = await alerts();
  h.eq('10 bans: one alert', a.length, 1);
  h.eq('alert is about the mod', a[0].actor, mod);
  h.eq('alert kind', a[0].kind, 'actions');
  h.eq('alert counts 10', a[0].action_count, 10);
  h.eq('alert lists the action', a[0].actions, ['ban']);
  h.eq('alert links the 10 log rows', a[0].links, 10);
  let n = await notices();
  h.eq('admin + 2 head mods told (not the paused head, not the mod)', n.map((x) => x.topic).sort(), [`user:${antic}`, `user:${head}`, `user:${head2}`].sort());
  h.eq('event name', n[0].event, 'mod_burst');
  h.eq('payload has id, actor_name, count', [typeof n[0].payload.id, n[0].payload.actor_name, n[0].payload.count, n[0].payload.kind], ['string', 'mod579', 10, 'actions']);

  // One alert per mod per hour: 10 more actions of a mixed kind, still one row and no second notice.
  await log(mod, 'timeout', 6);
  await log(mod, 'warn', 6);
  h.eq('more actions within the hour: still one alert', (await alerts()).length, 1);
  h.eq('no second round of notices', (await notices()).length, 3);
  // Even the deletes rule waits out the hour.
  await log(mod, 'delete', 45);
  h.eq('deletes burst inside the hour: still one alert', (await alerts()).length, 1);

  // Window: 10 bans spread over more than 10 minutes do not count together.
  await clear();
  await log(mod, 'ban', 6, '12 minutes');
  await log(mod, 'ban', 3);
  h.eq('6 old + 3 fresh bans: nothing', (await alerts()).length, 0);
  await log(mod, 'ban', 1);
  h.eq('6 old + 4 fresh: still nothing', (await alerts()).length, 0);

  // Mixed heavy actions count together (ban + kick + timeout).
  await clear();
  await log(mod, 'ban', 4);
  await log(mod, 'kick', 3);
  await log(mod, 'timeout', 3);
  a = await alerts();
  h.eq('mixed actions trip the rule', a.length, 1);
  h.eq('mixed actions listed', a[0].actions.sort(), ['ban', 'kick', 'timeout']);

  // Deletes have their own, higher bar.
  await clear();
  await log(mod, 'delete', 39);
  h.eq('39 deletes: nothing', (await alerts()).length, 0);
  await log(mod, 'delete', 1);
  a = await alerts();
  h.eq('40 deletes: alert', a.length, 1);
  h.eq('deletes kind', a[0].kind, 'deletes');
  h.eq('deletes count', a[0].action_count, 40);

  // Actions outside every rule never count; automatic entries (no actor) never count; admins never alert.
  await clear();
  await log(mod, 'verify', 30);
  await log(null, 'ban', 30);
  await log(antic, 'ban', 30);
  h.eq('verify x30, system x30, admin x30: nothing', (await alerts()).length, 0);

  // A head mod bursting alerts the other head mod and the admin, not themself.
  await clear();
  await log(head, 'ban', 10);
  n = await notices();
  h.eq('head mod burst: told the admin and the other head', n.map((x) => x.topic).sort(), [`user:${antic}`, `user:${head2}`].sort());

  // Test mode, flag on for Antic only (live today): the alert is written but only Antic is told.
  await clear();
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'mod_burst_alerts'`, [antic]);
  await log(mod, 'ban', 10);
  h.eq('flag on for Antic only: alert written', (await alerts()).length, 1);
  h.eq('flag on for Antic only: only Antic told', (await notices()).map((x) => x.topic), [`user:${antic}`]);
  await h.q(`update feature_flags set users = array[$1::uuid, $2::uuid, $3::uuid] where key = 'mod_burst_alerts'`, [antic, head, head2]);

  // Flag off: no alerts at all.
  await clear();
  await h.q(`update feature_flags set mode = 'off' where key = 'mod_burst_alerts'`);
  await log(mod, 'ban', 12);
  h.eq('flag off: nothing', (await alerts()).length, 0);
  await h.q(`update feature_flags set mode = 'test' where key = 'mod_burst_alerts'`);

  // Rules are the one place: lower the threshold and it applies at once.
  await clear();
  await h.q(`update mod_burst_rules set threshold = 3 where kind = 'actions'`);
  await log(mod, 'ban', 3);
  h.eq('threshold 3 from the rules table', (await alerts()).length, 1);
  await h.q(`update mod_burst_rules set threshold = 10 where kind = 'actions'`);
  await clear();
  await h.q(`update mod_burst_rules set enabled = false where kind = 'actions'`);
  await log(mod, 'ban', 12);
  h.eq('disabled rule: nothing', (await alerts()).length, 0);
  await h.q(`update mod_burst_rules set enabled = true where kind = 'actions'`);

  // Reading: Antic (flag on for him) sees it; head mods see it only once the flag is on for them; the mod and plain users never.
  await clear();
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'mod_burst_alerts'`, [antic]);
  await log(mod, 'ban', 10);
  const aid = (await h.one(`select id from mod_burst_alerts`)).id;
  await h.as(antic);
  h.eq('admin reads alerts', (await h.q(`select id from mod_burst_alerts`)).length, 1);
  h.eq('admin reads rules', (await h.q(`select kind from mod_burst_rules`)).length, 2);
  await h.as(head);
  h.eq('head mod outside the flag: sees nothing yet', (await h.q(`select id from mod_burst_alerts`)).length, 0);
  await h.admin();
  await h.q(`update feature_flags set users = array[$1::uuid, $2::uuid, $3::uuid, $4::uuid] where key = 'mod_burst_alerts'`, [antic, head, head2, mod]);
  await h.as(head);
  h.eq('head mod with the flag: reads the alert', (await h.q(`select id from mod_burst_alerts`)).length, 1);
  h.eq('head mod reads rules', (await h.q(`select kind from mod_burst_rules`)).length, 2);
  await h.as(mod);
  h.eq('plain mod (the actor): sees nothing', (await h.q(`select id from mod_burst_alerts`)).length, 0);
  h.eq('plain mod: no rules', (await h.q(`select kind from mod_burst_rules`)).length, 0);
  await h.fails('plain mod cannot write rules', `update mod_burst_rules set threshold = 1000`);
  await h.fails('plain mod cannot write alerts', `update mod_burst_alerts set dismissed_at = now()`);
  await h.as(plain);
  h.eq('plain user: nothing', (await h.q(`select id from mod_burst_alerts`)).length, 0);
  await h.fails('plain user cannot dismiss', `select mod_burst_dismiss($1, '')`, [aid]);
  await h.as(mod);
  await h.fails('plain mod cannot dismiss', `select mod_burst_dismiss($1, '')`, [aid]);

  // A head mod's own alert: hidden from them and not theirs to dismiss.
  await h.admin();
  await log(head, 'ban', 10);
  const own = (await h.one(`select id from mod_burst_alerts where actor = $1`, [head])).id;
  await h.as(head);
  h.eq('head mod does not see the alert about themself', (await h.q(`select id from mod_burst_alerts where id = $1`, [own])).length, 0);
  await h.fails('head mod cannot dismiss their own alert', `select mod_burst_dismiss($1, '')`, [own]);
  await h.as(head2);
  h.eq('the other head mod sees it', (await h.q(`select id from mod_burst_alerts where id = $1`, [own])).length, 1);

  // Dismiss: head mod with a note; logged; idempotent.
  await h.as(head);
  await h.ok('head mod dismisses with a note', () => h.q(`select mod_burst_dismiss($1, 'Spam wave, all fine')`, [aid]));
  await h.admin();
  const d = await h.one(`select dismissed_by, note, dismissed_at is not null done from mod_burst_alerts where id = $1`, [aid]);
  h.eq('dismissed by the head mod, note kept', d, { dismissed_by: head, note: 'Spam wave, all fine', done: true });
  const l = await h.one(`select actor, action, target_id, reason from mod_log where action = 'burst_reviewed'`);
  h.eq('dismiss is logged against the mod', l, { actor: head, action: 'burst_reviewed', target_id: mod, reason: 'actions x10: Spam wave, all fine' });
  await h.as(head2);
  await h.ok('dismissing again is a no-op', () => h.q(`select mod_burst_dismiss($1, 'again')`, [aid]));
  await h.admin();
  h.eq('first dismissal kept', (await h.one(`select dismissed_by from mod_burst_alerts where id = $1`, [aid])).dismissed_by, head);
  h.eq('no second log line', (await h.one(`select count(*)::int n from mod_log where action = 'burst_reviewed'`)).n, 1);
  await h.as(antic);
  await h.fails('no such alert', `select mod_burst_dismiss('00000000-0000-0000-0000-000000000000', '')`);
  await h.ok('admin dismisses the head mod one', () => h.q(`select mod_burst_dismiss($1, '')`, [own]));

  // Flag off for the reader: dismiss refused, reads empty.
  await h.admin();
  await h.q(`update feature_flags set users = '{}' where key = 'mod_burst_alerts'`);
  await h.as(antic);
  h.eq('flag off for the admin: reads nothing', (await h.q(`select id from mod_burst_alerts`)).length, 0);
  await h.fails('flag off for the admin: cannot dismiss', `select mod_burst_dismiss($1, '')`, [aid]);

  // Grants: internals are not callable from the client.
  await h.as(plain);
  await h.fails('recipients helper is internal', `select public.mod_burst_recipients(null)`);
  await h.fails('trigger function is internal', `select public.mod_burst_alert_check()`);
}
