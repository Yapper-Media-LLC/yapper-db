// 591: the gore_check_profiles flag row (data only). Re-runnable and starts in test mode for Antic.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '591_gore_check_profiles.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(MIG);
  await h.ok('591 re-runs cleanly', () => h.db.exec(MIG));
  const r = await h.one(`select mode, users from feature_flags where key = 'gore_check_profiles'`);
  h.eq('flag starts in test', r.mode, 'test');
  h.eq('test user is Antic', r.users, ['00000000-0000-4000-8000-00000000a001']);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'gore_check_profiles'`);
  await h.db.exec(MIG);
  h.eq('re-run keeps a published flag', (await h.one(`select mode from feature_flags where key = 'gore_check_profiles'`)).mode, 'everyone');
}
