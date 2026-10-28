// 280: username_taken() is server-only. A stand-in with the live signature; 280 must leave only the service role
// (and the owner) able to call it, and re-run cleanly.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
create or replace function public.username_taken(name text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where lower(username) = lower(name));
$$;
grant execute on function public.username_taken(text) to anon, authenticated, service_role;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '280_username_taken_server_only.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.signup('amy@test.dev', 'amy');
  await h.db.exec(MIG);
  await h.ok('280 re-runs cleanly', () => h.db.exec(MIG));

  await h.admin();
  for (const role of ['anon', 'authenticated']) {
    h.eq(`${role} can't call username_taken`, (await h.one(`select has_function_privilege($1, 'public.username_taken(text)', 'execute') ok`, [role])).ok, false);
  }
  h.eq('the service role still can', (await h.one(`select has_function_privilege('service_role', 'public.username_taken(text)', 'execute') ok`)).ok, true);

  await h.as(null);
  await h.fails('logged out: refused', `select username_taken('amy')`);
  const someone = await h.signup('bob@test.dev', 'bob');
  await h.as(someone);
  await h.fails('signed in: refused', `select username_taken('amy')`);
  await h.admin();
  h.eq('the server-side answer is unchanged', (await h.one(`select username_taken('AMY') t`)).t, true);
}
