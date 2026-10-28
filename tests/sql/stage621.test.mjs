// 621: plain site moderators can read staff applications but not decide them. Base and stand-ins as stage589, then
// 589, 613 and 621 on top, plus an is_site_mod stand-in.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage589.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(`create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null); $$;`);
  await h.db.exec(mig('589_staff_applications.sql'));
  await h.db.exec(mig('613_staff_apply_v2.sql'));
  await h.db.exec(mig('621_staff_apps_mods_view.sql'));
  await h.ok('621 re-runs cleanly', () => h.db.exec(mig('621_staff_apps_mods_view.sql')));

  const mod = await h.signup('mod621@test.dev', 'mod621');
  const paused = await h.signup('paused621@test.dev', 'paused621');
  const ann = await h.signup('ann621@test.dev', 'ann621');
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`insert into site_moderators (user_id, suspended_at) values ($1, now())`, [paused]);
  await h.q(`insert into staff_applications (user_id, why, hours) values ($1, 'I really want to help keep this place clean.', 'UTC')`, [ann]);
  const id = (await h.one(`select id from staff_applications where user_id = $1`, [ann])).id;

  await h.as(mod);
  h.eq('plain mod can list', (await h.q(`select * from staff_applications_list()`)).length, 1);
  await h.fails('plain mod cannot decide', `select decide_staff_application($1, true)`, [id]);
  await h.as(paused);
  await h.fails('paused mod cannot list', `select * from staff_applications_list()`);
  await h.as(ann);
  await h.fails('member cannot list', `select * from staff_applications_list()`);
  await h.as(null);
  await h.fails('anon cannot list', `select * from staff_applications_list()`);
}
