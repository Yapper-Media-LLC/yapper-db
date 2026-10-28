// 336: the avatars/banners Storage insert policy is gone (uploads go through R2), proofs and sounds still upload.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '336_drop_profile_image_upload_policy.sql'), 'utf8');
const SOUNDS = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '046_soundboard.sql'), 'utf8')
  .split('\n').filter((l) => l.startsWith('create policy "sounds: upload own folder"')).join('\n');

export default async function (h) {
  await h.admin();
  await h.db.exec(`insert into storage.buckets (id, name, public) values ('proofs', 'proofs', false), ('sounds', 'sounds', true) on conflict (id) do nothing;
    create policy "proofs: upload own" on storage.objects for insert to authenticated
      with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);
    ${SOUNDS}`);
  const a = await h.signup('alice@test.dev', 'alice');
  await h.as(a);
  await h.q(`insert into storage.objects (bucket_id, name) values ('avatars', $1)`, [`${a}/before.gif`]);

  await h.admin();
  await h.db.exec(MIG);
  await h.ok('336 re-runs cleanly', () => h.db.exec(MIG));

  await h.as(a);
  await h.fails('no direct avatar upload', `insert into storage.objects (bucket_id, name) values ('avatars', $1)`, [`${a}/x.png.still.webp`]);
  await h.fails('no direct banner upload', `insert into storage.objects (bucket_id, name) values ('banners', $1)`, [`${a}/b.gif`]);
  await h.q(`insert into storage.objects (bucket_id, name) values ('proofs', $1)`, [`${a}/proof.png`]);
  await h.q(`insert into storage.objects (bucket_id, name) values ('sounds', $1)`, [`${a}/boom.mp3`]);
  h.eq('own old avatar still listable', (await h.one(`select count(*)::int n from storage.objects where bucket_id = 'avatars'`)).n, 1);
}
