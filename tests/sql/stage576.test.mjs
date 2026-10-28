// 576: flag no_hq_autojoin + join_default_server() skipping HQ once the flag is published. Starts from stage 24
// (app_settings and the profiles trigger come from 012), adds the flags table (031/041) and a stand-in is_bot_user.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

export default async function (h) {
  const MIG = mig('576_no_hq_autojoin.sql');
  h.eq('576 has no drop / delete / truncate', /\b(drop|truncate|delete\s+from)\b/i.test(MIG.replace(/^--.*$/gm, '')), false);
  await h.admin();
  await h.db.exec(`
    create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from auth.users u where u.id = uid and coalesce(u.raw_user_meta_data ->> 'bot', '') = 'true') $$;
  `);
  const owner = await h.signup('hqowner@x.test', 'hqowner');
  const hq = (await h.q(`insert into servers (name, owner_id) values ('Yapper HQ', $1) returning id`, [owner]))[0].id;
  await h.q(`update app_settings set default_server_id = $1`, [hq]);

  await h.ok('576 runs', () => h.db.exec(MIG));
  await h.ok('576 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag row in test for Antic', (await h.q(`select mode, servers, users from feature_flags where key = 'no_hq_autojoin'`))[0],
    { mode: 'test', servers: [], users: ['00000000-0000-4000-8000-00000000a001'] });
  const def = (await h.q(`select pg_get_functiondef('public.join_default_server'::regproc) d`))[0].d;
  h.eq('still security definer with search_path', /SECURITY DEFINER[\s\S]*search_path/i.test(def), true);
  h.eq('trigger still on profiles', (await h.q(`select count(*)::int n from pg_trigger where tgname = 'profiles_join_default_server'`))[0].n, 1);

  const inHq = async (uid) => (await h.q(`select count(*)::int n from server_members where server_id = $1 and user_id = $2`, [hq, uid]))[0].n;

  // Flag in test: signup still joins HQ (can't be per-user at signup).
  const a = await h.signup('a@x.test', 'alice');
  h.eq('test mode: new account joins HQ', await inHq(a), 1);

  // Flag off: same.
  await h.q(`update feature_flags set mode = 'off' where key = 'no_hq_autojoin'`);
  const b = await h.signup('b@x.test', 'bob');
  h.eq('off: new account joins HQ', await inHq(b), 1);

  // Flag published: new accounts stay out of HQ. Existing members untouched.
  await h.q(`update feature_flags set mode = 'everyone' where key = 'no_hq_autojoin'`);
  const c = await h.signup('c@x.test', 'carol');
  h.eq('everyone: new account not in HQ', await inHq(c), 0);
  h.eq('everyone: no servers at all for the new account', (await h.q(`select count(*)::int n from server_members where user_id = $1`, [c]))[0].n, 0);
  h.eq('existing members kept', (await inHq(a)) + (await inHq(b)), 2);

  // Bots still skipped with the flag off.
  await h.q(`update feature_flags set mode = 'off' where key = 'no_hq_autojoin'`);
  const bot = (await h.q(`insert into auth.users (email, raw_user_meta_data) values ('bot@x.test', '{"username":"botty","bot":"true"}'::jsonb) returning id`))[0].id;
  h.eq('bot account not joined', await inHq(bot), 0);
  const d = await h.signup('d@x.test', 'dave');
  h.eq('off again: humans join HQ again', await inHq(d), 1);

  // Flag row re-insert does nothing once Antic changed the mode.
  await h.q(`update feature_flags set mode = 'everyone' where key = 'no_hq_autojoin'`);
  await h.db.exec(MIG);
  h.eq('re-run keeps the published mode', (await h.q(`select mode from feature_flags where key = 'no_hq_autojoin'`))[0].mode, 'everyone');
}
