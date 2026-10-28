// 235: queue case claims. Staff claim the case they look at; another mod's fresh claim wins and shows up for others.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
create table if not exists public.staff_standin (user_id uuid primary key);
grant select on public.staff_standin to authenticated;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '235_case_claims.sql'), 'utf8');
  await h.db.exec(sql);
  await h.ok('migration runs twice', () => h.db.exec(sql));
  const moon = await h.signup('m@x.com', 'moon');
  const kj = await h.signup('k@x.com', 'kj');
  const user = await h.signup('u@x.com', 'someone');
  await h.admin();
  await h.q(`insert into public.staff_standin values ($1), ($2)`, [moon, kj]);

  await h.as(user);
  await h.fails('non-staff cannot claim', `select public.claim_case('case-1')`);
  await h.as(moon);
  h.eq('moon claims case-1', (await h.one(`select public.claim_case('case-1') v`)).v, null);
  h.eq('moon sees no other claims', (await h.q(`select * from public.case_claims()`)).length, 0);
  await h.as(kj);
  h.eq('kj is told moon has it', (await h.one(`select public.claim_case('case-1') v`)).v, 'moon');
  h.eq('kj sees moon on case-1', (await h.q(`select case_key, username from public.case_claims()`)), [{ case_key: 'case-1', username: 'moon' }]);
  h.eq('kj takes case-2', (await h.one(`select public.claim_case('case-2') v`)).v, null);
  await h.as(moon);
  h.eq('moon refreshes own claim', (await h.one(`select public.claim_case('case-1') v`)).v, null);
  h.eq('moon moving on lets go of case-1', (await h.one(`select public.claim_case('case-3') v`)).v, null);
  await h.as(kj);
  h.eq('case-1 free again for kj', (await h.one(`select public.claim_case('case-1') v`)).v, null);
  await h.q(`select public.release_case('case-1')`);
  await h.as(moon);
  h.eq('released case is free', (await h.one(`select public.claim_case('case-1') v`)).v, null);
  await h.as(user);
  await h.fails('non-staff cannot read the table', `select * from public.mod_case_claims`);
  h.eq('non-staff list is empty', (await h.q(`select * from public.case_claims()`)).length, 0);
}
