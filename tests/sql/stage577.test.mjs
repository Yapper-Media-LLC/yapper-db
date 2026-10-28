// 577: the burst guard skips actions on accounts under 3 days old. Runs stage565 first (its stand-ins, 565 itself
// and its checks), then 577 on top, then a spam sweep on new accounts and the same burst on old ones.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import stage565 from './stage565.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '577_burst_guard_skips_new_accounts.sql'), 'utf8');

export default async function (h) {
  for (const bad of ['drop ', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`577 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await stage565(h);
  await h.admin();
  // Live mod_guard also carries 547's boost line (577 anchors on it).
  await h.db.exec(String.raw`
create table if not exists public.site_managers (user_id uuid primary key, added_by uuid, created_at timestamptz default now());
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null) $$;
create or replace function public.is_site_manager() returns boolean language sql stable security definer set search_path = public as $$ select false $$;
`);
  await h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', '547_mod_limit_boost.sql'), 'utf8'));
  await h.ok('577 runs', () => h.db.exec(MIG));
  await h.ok('577 re-runs cleanly', () => h.db.exec(MIG));
  const def = (await h.one(`select pg_get_functiondef('public.mod_burst_check()'::regprocedure) d`)).d;
  h.eq('patched once', def.split('-- 577:').length - 1, 1);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'mod_burst_guard'`);

  const mod = await h.signup('sweeper@x.com', 'sweeper');
  const mod2 = await h.signup('other@x.com', 'othermod');
  const fresh = await h.signup('bot1@x.com', 'spambot1');
  const old = await h.signup('old@x.com', 'oldtimer');
  await h.admin();
  for (const m of [mod, mod2]) await h.q(`insert into site_moderators (user_id) values ($1) on conflict do nothing`, [m]);
  await h.q(`update profiles set created_at = now() - interval '30 days' where id in ($1, $2, $3)`, [old, mod, mod2]);
  await h.q(`update profiles set created_at = now() - interval '1 day' where id = $1`, [fresh]);
  const paused = async (u) => !!(await h.one(`select suspended_at from site_moderators where user_id = $1`, [u]))?.suspended_at;

  // 80 deletes on a 1-day-old account in a few minutes: not counted, no pause, the check still passes.
  for (let i = 0; i < 80; i++) await h.q(`insert into mod_log (actor, action, target_id) values ($1, 'delete', $2)`, [mod, fresh]);
  await h.as(mod);
  await h.ok('spam sweep on new accounts passes the burst check', () => h.q(`select public.mod_guard('check', null, 'burst check')`));
  await h.admin();
  h.eq('and does not pause', await paused(mod), false);

  // The same burst on a 30-day-old account still pauses at 60, and so do rows with no target.
  for (let i = 0; i < 59; i++) await h.q(`insert into mod_log (actor, action, target_id) values ($1, 'delete', $2)`, [mod2, old]);
  await h.as(mod2);
  await h.ok('60th action on old accounts still goes through', () => h.q(`select public.mod_guard('check', null, 'burst check')`));
  await h.admin();
  h.eq('but pauses the mod', await paused(mod2), true);

  const mod3 = await h.signup('third@x.com', 'thirdmod');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod3]);
  for (let i = 0; i < 59; i++) await h.q(`insert into mod_log (actor, action) values ($1, 'deco_removed')`, [mod3]);
  await h.as(mod3);
  await h.ok('untargeted burst reaches the line', () => h.q(`select public.mod_guard('check', null, 'burst check')`));
  await h.admin();
  h.eq('untargeted burst still pauses', await paused(mod3), true);

  // Restorative actions on new accounts still count (no free verifies or unbans for fresh alts).
  const mod4 = await h.signup('fourth@x.com', 'fourthmod');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod4]);
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [mod4]);
  for (let i = 0; i < 59; i++) await h.q(`insert into mod_log (actor, action, target_id) values ($1, 'unban', $2)`, [mod4, fresh]);
  await h.as(mod4);
  await h.ok('59 unbans on a new account reach the line', () => h.q(`select public.mod_guard('check', null, 'burst check')`));
  await h.admin();
  h.eq('unbans on new accounts still pause', await paused(mod4), true);

  // mod_guard: deletes of a new account get 4x the hourly cap, bans don't.
  const mod5 = await h.signup('fifth@x.com', 'fifthmod');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod5]);
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [mod5]);
  await h.q(`update feature_flags set mode = 'off' where key = 'mod_burst_guard'`); // caps only
  for (let i = 0; i < 100; i++) await h.q(`insert into mod_log (actor, action, target_id) values ($1, 'delete', $2)`, [mod5, fresh]);
  await h.as(mod5);
  await h.ok('101st delete of a new account allowed (cap 240)', () => h.q(`select public.mod_guard('delete', $1, 'spam')`, [fresh]));
  await h.fails('delete of an old account past 60 refused', `select public.mod_guard('delete', $1, 'spam')`, [old]);
  await h.admin();
  for (let i = 0; i < 80; i++) await h.q(`insert into mod_log (actor, action, target_id) values ($1, 'ban', $2)`, [mod5, fresh]);
  await h.as(mod5);
  await h.fails('ban cap stays 80 on new accounts', `select public.mod_guard('ban', $1, 'spam bot')`, [fresh]);
  await h.admin();
  const g = (await h.one(`select pg_get_functiondef('public.mod_guard(text,uuid,text)'::regprocedure) d`)).d;
  h.eq('mod_guard patched once', g.split('-- 577:').length - 1, 1);
}
