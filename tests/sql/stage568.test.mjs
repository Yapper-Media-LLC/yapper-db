// 568: Community Helper badge. Starts from stage537's stand-ins (live admin_set_badge anchor lines) and runs 537 first,
// so the function carries the Management patches the way it does live.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG537 = mig('537_management_role.sql');
const MIG = mig('568_community_helper_badge.sql');
const PUB = mig('569_publish_community_helper.sql');
const CMS = mig('571_community_helper_to_cms.sql');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`568 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.q(`insert into feature_flags (key, label, mode) values ('head_mods', 'Head mods', 'everyone') on conflict (key) do nothing`);
  await h.q(`insert into feature_flags (key, label, mode, users) values ('head_mod_badges', 'x', 'test', '{}') on conflict (key) do nothing`);
  await h.db.exec(MIG537);
  await h.ok('568 runs', () => h.db.exec(MIG));
  await h.ok('568 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'community_helper'`)).mode, 'test');
  await h.ok('569 publishes it', () => h.db.exec(PUB));
  await h.ok('569 re-runs cleanly', () => h.db.exec(PUB));
  h.eq('flag on for everyone', (await h.one(`select mode from feature_flags where key = 'community_helper'`)).mode, 'everyone');
  const src = (await h.one(`select prosrc from pg_proc where proname = 'admin_set_badge'`)).prosrc;
  h.eq('allow-list patched once', src.split(`'creator_3', 'artist', 'community_helper')`).length - 1, 1);
  h.eq('head mod rule patched once', src.split(`badge in ('artist', 'community_helper')`).length - 1, 1);
  h.eq('537 patches still there', src.includes('manager_guard'), true);

  const admin = await h.signup('admin@test.dev', 'boss');
  const mgr = await h.signup('mgr@test.dev', 'manager');
  const head = await h.signup('head@test.dev', 'headmod');
  const mod = await h.signup('mod@test.dev', 'modder');
  const u = await h.signup('u@test.dev', 'someone');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'management'`, [admin]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, false)`, [head, mod]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const badges = async (uid) => { await h.admin(); return (await h.one(`select badges from profiles where id = $1`, [uid])).badges; };

  await h.as(admin);
  await h.ok('admin gives Community Helper', () => h.q(`select admin_set_badge($1, 'community_helper', true)`, [u]));
  h.eq('badge on the profile', (await badges(u)).includes('community_helper'), true);
  await h.as(admin);
  await h.ok('admin takes it back', () => h.q(`select admin_set_badge($1, 'community_helper', false)`, [u]));
  h.eq('badge gone', (await badges(u)).includes('community_helper'), false);
  h.eq('logged', (await h.one(`select count(*)::int n from mod_log where reason = 'community_helper' and action in ('badge_given', 'badge_removed')`)).n, 2);

  await h.as(mod);
  h.eq('mod cannot give it', await err(`select admin_set_badge($1, 'community_helper', true)`, [u]), 'Admins only');
  await h.as(head);
  h.eq('head mod without head_mod_badges cannot', await err(`select admin_set_badge($1, 'community_helper', true)`, [u]), 'Admins only');
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'head_mod_badges'`, [head]);
  await h.as(head);
  await h.ok('head mod with head_mod_badges gives it', () => h.q(`select admin_set_badge($1, 'community_helper', true)`, [u]));
  h.eq('head mod still cannot give partner', await err(`select admin_set_badge($1, 'partner', true)`, [u]), 'Admins only');
  h.eq('head mod cannot give it to themselves', await err(`select admin_set_badge($1, 'community_helper', true)`, [head]), 'You can\'t moderate an admin or another moderator');
  h.eq('given by the head mod', (await badges(u)).includes('community_helper'), true);

  await h.as(admin);
  await h.q(`select admin_set_manager($1, true)`, [mgr]);
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'management'`, [mgr]);
  await h.as(mgr);
  await h.ok('manager takes it off', () => h.q(`select admin_set_badge($1, 'community_helper', false)`, [u]));
  await h.ok('manager gives it', () => h.q(`select admin_set_badge($1, 'community_helper', true)`, [u]));
  h.eq('unknown keys still refused', await err(`select admin_set_badge($1, 'community_hero', true)`, [u]), 'Unknown badge');
  await h.admin();
  await h.q(`create or replace function public.rt_profile_changed(uids uuid[]) returns void language sql as $$ select $$`);
  const cm = await h.signup('cm@test.dev', 'cm');
  await h.admin();
  await h.q(`insert into site_community_managers (user_id) values ($1)`, [cm]);
  await h.q(`update profiles set shown_badge = 'community_manager' where id = $1`, [cm]);
  await h.ok('571 gives CMs the badge', () => h.db.exec(CMS));
  await h.ok('571 re-runs cleanly', () => h.db.exec(CMS));
  h.eq('CM has it', (await badges(cm)).includes('community_helper'), true);
  h.eq('CM shown badge untouched', (await h.one(`select shown_badge from profiles where id = $1`, [cm])).shown_badge, 'community_manager');
  h.eq('logged once as badge_auto', (await h.one(`select count(*)::int n from mod_log where action = 'badge_auto' and reason = 'community_helper'`)).n, 1);
  h.eq('the test user and the CM have it', (await h.one(`select count(*)::int n from profiles where 'community_helper' = any(badges)`)).n, 2);
}
