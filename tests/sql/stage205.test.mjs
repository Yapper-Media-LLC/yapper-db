// 205: api_hetzner flag row (browser REST calls to our own PostgREST). Re-runnable, test mode, no servers yet.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '205_api_hetzner_flag.sql'), 'utf8');
  await h.db.exec(sql);
  await h.db.exec(sql); // re-runnable
  h.eq('flag row once, test mode, no servers', await h.q(`select mode, servers from feature_flags where key = 'api_hetzner'`), [{ mode: 'test', servers: [] }]);
  await h.db.exec(`update feature_flags set servers = array['00000000-0000-4000-8000-000000000001']::uuid[] where key = 'api_hetzner'`);
  await h.db.exec(sql); // a re-run never resets an admin's rollout
  h.eq('re-run keeps servers', (await h.q(`select servers from feature_flags where key = 'api_hetzner'`))[0].servers.length, 1);
}
