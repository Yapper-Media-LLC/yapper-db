// 293: the confirm_logout flag row. Test mode for the Yapper test server and Antic's account, and re-running
// never changes a flag an admin has already moved.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

// The live shape of feature_flags (031 + 041), without the Supabase bits 031 also sets up.
const STANDINS = `
create table if not exists public.feature_flags (
  key text primary key,
  label text not null,
  description text not null default '',
  mode text not null default 'off' check (mode in ('off', 'test', 'everyone')),
  servers uuid[] not null default '{}',
  users uuid[] not null default '{}',
  updated_at timestamptz not null default now(),
  updated_by uuid
);
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '293_confirm_logout_flag.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  const row = await h.one(`select mode, servers, users, label, description from public.feature_flags where key = 'confirm_logout'`);
  h.eq('flag is in test mode', row.mode, 'test');
  h.eq('the Yapper test server', JSON.stringify(row.servers), JSON.stringify(['00000000-0000-4000-8000-00000000b001']));
  h.eq('and Antic', JSON.stringify(row.users), JSON.stringify(['00000000-0000-4000-8000-00000000a001']));
  h.eq('no em dash in the text admins read', /—/.test(row.label + row.description), false);
  await h.db.exec(`update public.feature_flags set mode = 'everyone' where key = 'confirm_logout'`);
  await h.ok('293 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('re-running keeps what an admin set', (await h.one(`select mode from public.feature_flags where key = 'confirm_logout'`)).mode, 'everyone');
}
