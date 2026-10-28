// 403: channel_overrides read policy as a set check. The table comes from 142, which PGlite can't run, so a
// stand-in with the same columns and the old policy is made here; 403 is then applied on top of it.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;

const STANDIN = `
create table if not exists public.channel_overrides (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  channel_id uuid references public.channels(id) on delete cascade,
  category_id uuid,
  role_id uuid,
  allow text[] not null default '{}',
  deny text[] not null default '{}'
);
create index if not exists channel_overrides_server_idx on public.channel_overrides(server_id);
alter table public.channel_overrides enable row level security;
grant select on public.channel_overrides to authenticated;
create policy "members read overrides" on public.channel_overrides for select to authenticated using (
  (channel_id is not null and public.can_access_channel(channel_id))
  or (category_id is not null and public.is_server_member(server_id))
);
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDIN);
  const MIG = mig('403_overrides_read_set.sql');
  await h.ok('403 applies', () => h.db.exec(MIG));
  await h.ok('403 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('exactly one read policy', (await h.one(`select count(*)::int n from pg_policies where tablename = 'channel_overrides' and cmd = 'SELECT'`)).n, 1);
  h.eq('it is the set check, with no per-row function', (await h.one(
    `select (qual ilike '%my_server_ids%' and qual not ilike '%can_access_channel%') as ok from pg_policies where tablename = 'channel_overrides' and cmd = 'SELECT'`)).ok, true);

  const owner = await h.signup('owner@test.dev', 'owner');
  const member = await h.signup('member@test.dev', 'member');
  const outsider = await h.signup('outsider@test.dev', 'outsider');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, owner, member]);
  const cid = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [sid])).id;
  await h.q(`insert into channel_overrides (server_id, channel_id, allow) values ($1, $2, '{send_messages}')`, [sid, cid]);
  await h.q(`insert into channel_overrides (server_id, category_id, deny) values ($1, gen_random_uuid(), '{view_channel}')`, [sid]);
  // A private channel the member can't open: its override row is readable (the documented change), the channel row is not.
  const priv = (await h.one(`insert into channels (server_id, name, kind, private) values ($1, 'staff', 'text', true) returning id`, [sid])).id;
  await h.q(`insert into channel_overrides (server_id, channel_id, deny) values ($1, $2, '{view_channel}')`, [sid, priv]);

  await h.as(member);
  h.eq('a member reads the server\'s overrides', (await h.one(`select count(*)::int n from channel_overrides`)).n, 3);
  h.eq('including the row of a private channel they cannot open', (await h.one(`select count(*)::int n from channel_overrides where channel_id = $1`, [priv])).n, 1);
  h.eq('while that channel row itself stays hidden', (await h.one(`select count(*)::int n from channels where id = $1`, [priv])).n, 0);
  await h.as(owner);
  h.eq('the owner reads them too', (await h.one(`select count(*)::int n from channel_overrides`)).n, 3);
  await h.as(outsider);
  h.eq('someone outside the server reads none', (await h.one(`select count(*)::int n from channel_overrides`)).n, 0);
}
