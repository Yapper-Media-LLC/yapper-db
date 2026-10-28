// 320: banned_dm_partners only names banned people you share a DM with.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '320_banned_dm_partners.sql'), 'utf8');
const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;
create table if not exists public.feature_flags (key text primary key, label text not null default '', description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
`;
export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('320 re-runs cleanly', () => h.db.exec(MIG));
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', $2, $1) returning id`, [amy, amy + ':' + bob])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, amy, bob]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'bot'), ($2, 'bot')`, [bob, cat]);
  await h.as(amy);
  h.eq('amy sees bob (shared DM), not cat', (await h.q(`select * from banned_dm_partners() x`)).map((r) => Object.values(r)[0]), [bob]);
  await h.as(null);
  await h.fails('anon cannot call it', `select * from banned_dm_partners()`);
  await h.admin();
}
