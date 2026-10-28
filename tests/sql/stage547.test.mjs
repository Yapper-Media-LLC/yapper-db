// 547: mod limit boost (flag mod_limit_boost). Starts from stage 24 with stand-ins for the staff tables and the live
// mod_guard (trimmed to its limit check, with the "(% an hour)" message the app shows).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '547_mod_limit_boost.sql'), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.site_admins (user_id uuid primary key);
create table if not exists public.site_moderators (user_id uuid primary key, added_by uuid, created_at timestamptz default now(),
  suspended_at timestamptz, suspended_reason text, head boolean not null default false);
create table if not exists public.site_managers (user_id uuid primary key, added_by uuid, created_at timestamptz default now());
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) $$;
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null) $$;
create or replace function public.is_site_manager() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_managers m join public.site_moderators s on s.user_id = m.user_id where m.user_id = auth.uid() and s.head and s.suspended_at is null) $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid) $$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $f$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  lim := case action when 'ban' then 80 when 'badge' then 10 else 60 end;
  logged := array[action];
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then
    raise exception 'You''ve hit the hourly limit for that (% an hour). Wait a bit or ask an admin to do it.', lim;
  end if;
end; $f$;
grant execute on function public.mod_guard(text, uuid, text) to authenticated;
`;

const CAP = (n) => `You've hit the hourly limit for that (${n} an hour). Wait a bit or ask an admin to do it.`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`547 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.q(`insert into public.app_settings (id) values (true) on conflict do nothing`);
  await h.ok('547 runs', () => h.db.exec(MIG));
  await h.ok('547 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'mod_limit_boost'`)).mode, 'test');
  h.eq('mod_guard patched once', (await h.one(`select (length(prosrc) - length(replace(prosrc, 'mod_limit_boost', ''))) / length('mod_limit_boost') n from pg_proc where proname = 'mod_guard'`)).n, 1);
  h.eq('default is 1x', Number((await h.one(`select mod_limit_boost from app_settings`)).mod_limit_boost), 1);

  const admin = await h.signup('admin@test.dev', 'boss');
  const mgr = await h.signup('mgr@test.dev', 'manager');
  const head = await h.signup('head@test.dev', 'headmod');
  const mod = await h.signup('mod@test.dev', 'modder');
  const u = await h.signup('u@test.dev', 'someone');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, true), ($3, false)`, [mgr, head, mod]);
  await h.q(`insert into site_managers (user_id) values ($1)`, [mgr]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const boost = async () => Number((await h.one(`select mod_limit_boost() b`)).b);
  const fill = async (uid, action, n) => { await h.admin(); await h.q(`insert into mod_log (actor, action, created_at) select $1, $2, now() from generate_series(1, $3::int)`, [uid, action, n]); };

  // Default: 60 timeouts an hour, as today.
  await fill(mod, 'timeout', 60);
  await h.as(mod);
  h.eq('mod reads 1x', await boost(), 1);
  h.eq('60 timeouts hit the cap at 1x', await err(`select mod_guard('timeout', $1, 'spamming a lot')`, [u]), CAP(60));

  // Who may change it.
  h.eq('plain mod cannot raise it', await err(`select set_mod_limit_boost(2)`), 'Head mods and Management only');
  await h.as(null);
  h.eq('anon cannot', await err(`select set_mod_limit_boost(2)`), 'permission denied for function set_mod_limit_boost');
  await h.as(head);
  h.eq('head mod needs the flag', await err(`select set_mod_limit_boost(2)`), 'Not available yet');
  await h.as(mod);
  await err(`update app_settings set mod_limit_boost = 2.5`);
  h.eq('mod cannot write app_settings directly', await boost(), 1);
  await h.admin();
  await h.q(`update feature_flags set users = array[$1::uuid, $2::uuid] where key = 'mod_limit_boost'`, [head, mgr]);

  // A manager sets 2x: the cap becomes 120 and the toast says so.
  await h.as(mgr);
  await h.ok('manager sets 2x', () => h.q(`select set_mod_limit_boost(2)`));
  h.eq('now 2x', await boost(), 2);
  await h.as(mod);
  await h.ok('60 timeouts pass at 2x', () => h.q(`select mod_guard('timeout', $1, 'spamming a lot')`, [u]));
  await fill(mod, 'timeout', 60);
  await h.as(mod);
  h.eq('120 timeouts hit the cap at 2x', await err(`select mod_guard('timeout', $1, 'spamming a lot')`, [u]), CAP(120));
  await h.admin();
  h.eq('logged', await h.one(`select actor, reason from mod_log where action = 'mod_limit_boost'`), { actor: mgr, reason: '1x -> 2x' });

  // A head mod sets 1.5x (rounded up: 10 badges become 15).
  await h.as(head);
  await h.ok('head mod sets 1.5x', () => h.q(`select set_mod_limit_boost(1.5)`));
  await h.ok('same value again is a no-op', () => h.q(`select set_mod_limit_boost(1.5)`));
  await fill(head, 'badge', 15);
  await h.as(head);
  h.eq('1.5x: 10 badges become 15', await err(`select mod_guard('badge', $1, null)`, [u]), CAP(15));
  await h.admin();
  h.eq('two log rows, not three', (await h.one(`select count(*)::int n from mod_log where action = 'mod_limit_boost'`)).n, 2);
  h.eq('second says 2x -> 1.5x', (await h.one(`select reason from mod_log where action = 'mod_limit_boost' order by id desc limit 1`)).reason, '2x -> 1.5x');

  // Bad values.
  await h.as(mgr);
  for (const v of ['3', '0', '-1', '1.75', 'null']) {
    h.eq(`${v} refused`, await err(`select set_mod_limit_boost(${v})`), 'Pick 1x, 1.5x, 2x or 2.5x');
  }
  await h.admin();
  h.eq('the column refuses odd values too', (await err(`update app_settings set mod_limit_boost = 4`)).includes('app_settings_mod_limit_boost_check'), true);

  // 10 changes an hour for head mods and managers.
  await fill(mgr, 'mod_limit_boost', 9);
  await h.as(mgr);
  h.eq('10th change this hour refused', await err(`select set_mod_limit_boost(2)`), 'You\'ve changed the limits 10 times this hour. Wait a bit');
  h.eq('still 1.5x', await boost(), 1.5);

  // Admins set it without the flag; 2.5x.
  await h.admin();
  await h.q(`update feature_flags set users = '{}' where key = 'mod_limit_boost'`);
  await h.as(admin);
  await h.ok('admin sets 2.5x without the flag', () => h.q(`select set_mod_limit_boost(2.5)`));
  await h.as(mod);
  h.eq('mod reads 2.5x', await boost(), 2.5);
  await fill(mod, 'ban', 199);
  await h.as(mod);
  await h.ok('199 bans pass at 2.5x (cap 200)', () => h.q(`select mod_guard('ban', $1, 'spamming a lot')`, [u]));
  await h.as(head);
  h.eq('head mod refused without the flag again', await err(`select set_mod_limit_boost(1)`), 'Not available yet');
}
