// 340: Creator badge tiers through admin_set_badge. Starts from stage 24 with stand-ins for what the function uses
// (staff checks, mod_guard, mod_log, the badge columns, feature_flags).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '340_creator_badges.sql'), 'utf8');

const STANDINS = `
create table if not exists public.t340_admins (id uuid primary key);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
alter table public.mod_log add column if not exists target_id uuid;
alter table public.mod_log add column if not exists reason text;
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select exists (select 1 from public.t340_admins where id = auth.uid()) $$;
create or replace function public.is_site_mod() returns boolean language sql stable as $$ select false $$;
create or replace function public.mod_guard(a text, uid uuid, x text) returns void language sql as $$ select $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('340 re-runs cleanly', () => h.db.exec(MIG));
  const admin = await h.signup('admin@test.dev', 'admin');
  const user = await h.signup('u@test.dev', 'creator');
  const rando = await h.signup('r@test.dev', 'rando');
  await h.admin();
  await h.q(`insert into t340_admins values ($1)`, [admin]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { await h.q(sql, args); return 'ok'; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const row = async () => (await h.q(`select badges, shown_badge from profiles where id = $1`, [user]))[0];

  h.eq('admin gives Creator tier 1', await call(admin, `select admin_set_badge($1, 'creator_1', true)`, [user]), 'ok');
  await h.q(`update profiles set badges = badges || 'bug_hunter'::text, shown_badge = 'creator_1' where id = $1`, [user]);
  h.eq('upgrading to tier 2', await call(admin, `select admin_set_badge($1, 'creator_2', true)`, [user]), 'ok');
  let r = await row();
  h.eq('tier 1 is gone, tier 2 is there', [r.badges.includes('creator_1'), r.badges.includes('creator_2')], [false, true]);
  h.eq('other badges stay', r.badges.includes('bug_hunter'), true);
  h.eq('the shown badge follows the upgrade', r.shown_badge, 'creator_2');

  await h.q(`update profiles set shown_badge = 'bug_hunter' where id = $1`, [user]);
  h.eq('tier 3', await call(admin, `select admin_set_badge($1, 'creator_3', true)`, [user]), 'ok');
  r = await row();
  h.eq('only tier 3 left of the tiers', r.badges.filter((b) => b.startsWith('creator_')), ['creator_3']);
  h.eq('a non-creator shown badge is left alone', r.shown_badge, 'bug_hunter');

  h.eq('giving a non-tier badge leaves the tier', await call(admin, `select admin_set_badge($1, 'partner', true)`, [user]), 'ok');
  h.eq('...still tier 3', (await row()).badges.includes('creator_3'), true);

  await h.q(`update profiles set shown_badge = 'creator_3' where id = $1`, [user]);
  h.eq('taking tier 3 off', await call(admin, `select admin_set_badge($1, 'creator_3', false)`, [user]), 'ok');
  r = await row();
  h.eq('no tier left, shown badge cleared', [r.badges.some((b) => b.startsWith('creator_')), r.shown_badge], [false, null]);

  h.eq('community_manager can be given now', await call(admin, `select admin_set_badge($1, 'community_manager', true)`, [user]), 'ok');
  h.eq('unknown badges still refused', await call(admin, `select admin_set_badge($1, 'creator_4', true)`, [user]), 'Unknown badge');
  h.eq('non-admins can not hand out tiers', await call(rando, `select admin_set_badge($1, 'creator_1', true)`, [rando]), 'Admins only');
  h.eq('two log rows per give/take (one each)', Number((await h.q(`select count(*)::int n from mod_log where target_id = $1 and reason = 'creator_3'`, [user]))[0].n), 2);
  h.eq('flag row is in test mode', (await h.q(`select mode from feature_flags where key = 'creator_badges'`))[0].mode, 'test');
}
