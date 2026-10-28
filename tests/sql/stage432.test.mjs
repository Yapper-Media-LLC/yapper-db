// 432: you can delete your own files in the proofs bucket, but not someone else's, and not proof on a warning or ban.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '432_proofs_delete_own.sql'), 'utf8');

const STANDINS = `
insert into storage.buckets (id, name) values ('proofs', 'proofs') on conflict do nothing;
create table if not exists public.user_warnings (id uuid primary key default gen_random_uuid(), user_id uuid, proof jsonb);
create table if not exists public.site_bans (user_id uuid primary key, proof jsonb);
alter table public.site_bans add column if not exists proof jsonb;
alter table public.user_warnings add column if not exists proof jsonb;
create table if not exists public.verification_requests (id uuid primary key default gen_random_uuid(), proof_path text, status text);
create policy "proofs: read own" on storage.objects for select to authenticated
  using (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);
`;

export default async function (h) {
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('432 re-runs cleanly', () => h.db.exec(MIG));
  const put = (name) => h.q(`insert into storage.objects (bucket_id, name, owner) values ('proofs', $1, null)`, [name]);
  await put(`${amy}/verify.png`);
  await put(`${amy}/warn.png`);
  await put(`${amy}/ban.png`);
  await put(`${bob}/bug.png`);
  await put(`${amy}/pending.png`);
  await put(`${amy}/rejected.png`);
  await h.q(`insert into verification_requests (proof_path, status) values ($1, 'pending'), ($2, 'rejected')`, [`${amy}/pending.png`, `${amy}/rejected.png`]);
  await h.q(`insert into user_warnings (user_id, proof) values ($1, $2)`, [bob, JSON.stringify({ images: [`${amy}/warn.png`] })]);
  await h.q(`insert into site_bans (user_id, proof) values ($1, $2)`, [bob, JSON.stringify({ images: [`${amy}/ban.png`] })]);

  const del = async (name) => (await h.q(`delete from storage.objects where bucket_id = 'proofs' and name = $1 returning name`, [name])).length;
  await h.as(amy);
  h.eq('amy deletes her own proof', await del(`${amy}/verify.png`), 1);
  h.eq('but not proof on a warning', await del(`${amy}/warn.png`), 0);
  h.eq('or on a ban', await del(`${amy}/ban.png`), 0);
  h.eq('and not bob\'s file', await del(`${bob}/bug.png`), 0);
  h.eq('not a proof waiting for review', await del(`${amy}/pending.png`), 0);
  h.eq('but a rejected one, yes', await del(`${amy}/rejected.png`), 1);
  h.eq('the helper calls bob\'s file evidence (no probing)', (await h.one(`select proof_is_evidence($1) v`, [`${bob}/bug.png`])).v, true);
  await h.as(bob);
  h.eq('bob deletes his own', await del(`${bob}/bug.png`), 1);
  await h.as(null);
  await h.fails('anon cannot call the helper', `select public.proof_is_evidence('x')`);
}
