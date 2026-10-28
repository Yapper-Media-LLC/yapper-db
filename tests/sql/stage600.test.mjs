// 600: app_host.secrets + app_host_secrets(): only service_role reads them; anon and signed-in users can't see,
// list, call or write anything.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;

export default async function (h) {
  await h.admin();
  const MIG = mig('600_app_host_secrets.sql');
  await h.ok('600 runs', () => h.db.exec(MIG));
  await h.ok('600 re-runs cleanly', () => h.db.exec(MIG));
  await h.q(`insert into app_host.secrets (name, value) values ('LIVEKIT_API_KEY', 'k1'), ('LIVEKIT_API_SECRET', 's1')`);
  await h.q(`insert into app_host.secrets (name, value) values ('LIVEKIT_API_KEY', 'k2') on conflict (name) do update set value = excluded.value, updated_at = now()`);
  await h.fails('bad name refused', `insert into app_host.secrets (name, value) values ('bad name', 'x')`);
  await h.fails('empty value refused', `insert into app_host.secrets (name, value) values ('EMPTY', '')`);

  await h.db.exec('set role service_role;');
  h.eq('service_role reads them', (await h.one(`select public.app_host_secrets() s`)).s, { LIVEKIT_API_KEY: 'k2', LIVEKIT_API_SECRET: 's1' });
  await h.admin();

  const u = await h.signup('someone@test.dev', 'someone');
  await h.as(u);
  await h.fails('signed-in user cannot call it', `select public.app_host_secrets()`);
  await h.fails('signed-in user cannot read the table', `select * from app_host.secrets`);
  await h.fails('signed-in user cannot write the table', `insert into app_host.secrets (name, value) values ('X', 'y')`);
  await h.as(null);
  await h.fails('anon cannot call it', `select public.app_host_secrets()`);
  await h.fails('anon cannot read the table', `select * from app_host.secrets`);
  await h.admin();
  h.eq('nothing extra was written', (await h.one(`select count(*)::int n from app_host.secrets`)).n, 2);
}
