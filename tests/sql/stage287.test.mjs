// 287: the new_look flag row. Test mode for Antic's account only: no servers (a listed server turns it on for
// all its members), and re-running never changes a flag an admin has already moved.
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
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '287_new_look_flag.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  const row = await h.one(`select mode, servers, users from public.feature_flags where key = 'new_look'`);
  h.eq('flag is in test mode', row.mode, 'test');
  h.eq('no test servers (would turn it on for their members)', row.servers.length, 0);
  h.eq('only Antic', JSON.stringify(row.users), JSON.stringify(['00000000-0000-4000-8000-00000000a001']));
  await h.db.exec(`update public.feature_flags set mode = 'everyone' where key = 'new_look'`);
  await h.ok('287 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('re-running keeps what an admin set', (await h.one(`select mode from public.feature_flags where key = 'new_look'`)).mode, 'everyone');
}
