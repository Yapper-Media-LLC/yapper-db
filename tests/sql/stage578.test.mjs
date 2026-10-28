// 578: publish no_hq_autojoin. Data only; after 576 the row flips to everyone and a new signup stays out of HQ.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

export default async function (h) {
  const PUB = mig('578_publish_no_hq_autojoin.sql');
  h.eq('578 is data only', /\b(create|alter|drop|grant|delete\s+from|truncate)\b/i.test(PUB.replace(/^--.*$/gm, '')), false);
  await h.admin();
  await h.db.exec(`create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$ select false $$;`);
  const owner = await h.signup('hqowner@x.test', 'hqowner');
  const hq = (await h.q(`insert into servers (name, owner_id) values ('Yapper HQ', $1) returning id`, [owner]))[0].id;
  await h.q(`update app_settings set default_server_id = $1`, [hq]);
  await h.db.exec(mig('576_no_hq_autojoin.sql'));
  const before = await h.signup('before@x.test', 'before');
  await h.ok('578 runs', () => h.db.exec(PUB));
  await h.ok('578 re-runs cleanly', () => h.db.exec(PUB));
  h.eq('flag is everyone', (await h.q(`select mode from feature_flags where key = 'no_hq_autojoin'`))[0].mode, 'everyone');
  const u = await h.signup('new@x.test', 'newbie');
  h.eq('new account not in HQ', (await h.q(`select count(*)::int n from server_members where server_id = $1 and user_id = $2`, [hq, u]))[0].n, 0);
  h.eq('earlier account still in HQ', (await h.q(`select count(*)::int n from server_members where server_id = $1 and user_id = $2`, [hq, before]))[0].n, 1);
}
