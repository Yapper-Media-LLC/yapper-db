// 335: unused table privileges are gone, and everything a policy allows still works. Checks, over every public table:
// anon keeps no insert/update/delete; authenticated keeps exactly the write grants some policy covers (none lost, none
// extra); nobody keeps truncate/trigger/references. Then a normal user still edits their profile, makes a server and
// posts in it. Starts from stage 24 (its tables, policies and Supabase-style default grants).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '335_revoke_unused_table_grants.sql'), 'utf8');

// (table, privilege) pairs a role holds at table level in public.
const grants = async (h, role, privs) => (await h.q(
  `select table_name || ':' || privilege_type k from information_schema.role_table_grants
   where table_schema = 'public' and grantee = $1 and privilege_type = any($2) order by 1`, [role, privs])).map((r) => r.k);
// authenticated write grants that a permissive policy (for authenticated or public) covers. Update counts as covered
// where inserts are allowed: upserts need it up front.
const usable = async (h) => (await h.q(
  `select g.table_name || ':' || g.privilege_type k from information_schema.role_table_grants g
   where g.table_schema = 'public' and g.grantee = 'authenticated' and g.privilege_type in ('INSERT', 'UPDATE', 'DELETE')
     and exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = g.table_name
                 and p.permissive = 'PERMISSIVE'
                 and (p.cmd in (g.privilege_type, 'ALL') or (g.privilege_type = 'UPDATE' and p.cmd = 'INSERT'))
                 and p.roles && array['authenticated', 'public']::name[])
   order by 1`)).map((r) => r.k);

export default async function (h) {
  await h.admin();
  await h.db.exec(`grant all on all tables in schema public to anon, authenticated`); // Supabase's defaults
  const before = await usable(h);
  h.eq('stage 24 has some policy-backed writes to keep', before.length > 0, true);

  await h.db.exec(MIG);
  await h.ok('335 re-runs cleanly', () => h.db.exec(MIG));

  h.eq('anon: no insert/update/delete anywhere', await grants(h, 'anon', ['INSERT', 'UPDATE', 'DELETE']), []);
  h.eq('nobody keeps truncate/trigger/references',
    [...await grants(h, 'anon', ['TRUNCATE', 'TRIGGER', 'REFERENCES']), ...await grants(h, 'authenticated', ['TRUNCATE', 'TRIGGER', 'REFERENCES'])], []);
  h.eq('authenticated keeps every write a policy allows', await usable(h), before);
  h.eq('and no write grant without a policy', await grants(h, 'authenticated', ['INSERT', 'UPDATE', 'DELETE']), before);
  h.eq('reads are untouched', (await grants(h, 'authenticated', ['SELECT'])).length > 0, true);

  // A normal user still does normal things.
  const amy = await h.signup('amy@test.dev', 'amy');
  await h.as(amy);
  await h.ok('edits their own profile', () => h.q(`update profiles set username = 'amy2' where id = $1`, [amy]));
  const sid = (await h.one(`select create_server('Amys', null) id`)).id;
  const cid = (await h.one(`select id from channels where server_id = $1 limit 1`, [sid])).id;
  await h.ok('posts a message', () => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [cid, amy]));
  await h.fails('still can not make themselves an admin (no grant, no policy)', `insert into site_admins (user_id) values ($1)`, [amy]);
  // An upsert on a table with an insert policy but no update policy still works (server_mutes in the app).
  await h.admin();
  await h.db.exec(`create table if not exists public.t335_mutes (user_id uuid primary key, until timestamptz);
    alter table public.t335_mutes enable row level security;
    create policy "t335 own insert" on public.t335_mutes for insert to authenticated with check (user_id = auth.uid());
    create policy "t335 own read" on public.t335_mutes for select to authenticated using (user_id = auth.uid());
    grant all on public.t335_mutes to anon, authenticated;`);
  await h.db.exec(MIG);
  await h.as(amy);
  await h.ok('upsert (insert path) still works', () => h.q(`insert into t335_mutes values ($1, now()) on conflict (user_id) do update set until = excluded.until`, [amy]));
  await h.admin();
  h.eq('t335: anon lost everything, authenticated kept insert + update, lost delete',
    [await grants(h, 'anon', ['INSERT', 'UPDATE', 'DELETE']), (await grants(h, 'authenticated', ['INSERT', 'UPDATE', 'DELETE'])).filter((k) => k.startsWith('t335_'))],
    [[], ['t335_mutes:INSERT', 't335_mutes:UPDATE']]);
  await h.as(null);
  await h.fails('logged out: can not post', `insert into messages (channel_id, author_id, content) values ($1, $2, 'x')`, [cid, amy]);
}
