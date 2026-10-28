// 529: the 2-character names held by banned script accounts on 1sec.email / 5vra.com / grr.la move to a hold owned
// by Antic. Same base as 277 (001..024, flags 031/041, 246 holds), stand-ins for site_moderators, bots, mod_log and
// the live is_staff.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const ANTIC = '00000000-0000-4000-8000-00000000a001';
const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (user_id uuid primary key);
alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('246_username_holds.sql'));
  const MIG = mig('529_short_name_takeover.sql');

  // Before Antic's profile exists the migration does nothing.
  await h.ok('529 is a no-op without Antic\'s profile', () => h.db.exec(MIG));

  await h.db.query(`insert into auth.users (id, email, raw_user_meta_data) values ($1, 'antic@test.dev', '{"username":"Antic"}')`, [ANTIC]);
  const a8 = await h.signup('a8@test.dev', 'a8');
  const b6 = await h.signup('b6@test.dev', 'B6');
  const g1 = await h.signup('g1@test.dev', 'g1');
  const free = await h.signup('k9@test.dev', 'k9');      // not banned
  const real = await h.signup('me@gmail.com', 'hi');       // banned, normal mail
  const long = await h.signup('long@test.dev', 'long');    // banned, longer name
  const mod = await h.signup('mo@test.dev', 'mo');            // banned, but a moderator
  const old = await h.signup('ol@test.dev', 'ol');          // ban ran out
  await h.admin();
  // Sign-up refuses throwaway mail (as live does now); these accounts got in before that, so set the address after.
  await h.q(`alter table auth.users disable trigger user`);
  for (const [id, mail] of [[a8, 'xq1@1sec.email'], [b6, 'zz@5VRA.com'], [g1, 'r@grr.la'], [free, 'k@1sec.email'], [long, 'lo@1sec.email'], [mod, 'm@grr.la'], [old, 'o@5vra.com']]) {
    await h.q(`update auth.users set email = $2 where id = $1`, [id, mail]);
  }
  await h.q(`alter table auth.users enable trigger user`);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`insert into site_bans (user_id, reason) select unnest($1::uuid[]), 'scripted sign-ups'`, [[a8, b6, g1, real, long, mod]]);
  await h.q(`insert into site_bans (user_id, reason, expires_at) values ($1, 'old', now() - interval '1 day')`, [old]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'username_limits'`);

  // Live expects 103; with any other count it refuses and changes nothing.
  await h.fails('a different count than expected is refused', MIG);
  h.eq('nothing taken after the refusal', (await h.q(`select 1 from username_holds`)).length, 0);
  await h.db.exec(`select set_config('yapper.takeover_expect', '3', false)`);
  await h.db.exec(MIG);
  const name = async (id) => (await h.one(`select username from profiles where id = $1`, [id])).username;
  for (const [id, was] of [[a8, 'a8'], [b6, 'B6'], [g1, 'g1']]) {
    h.eq(`${was} is renamed to banned_<id>`, await name(id), 'banned_' + id.replace(/-/g, '').slice(0, 16));
  }
  for (const [id, was] of [[free, 'k9'], [real, 'hi'], [long, 'long'], [mod, 'mo'], [old, 'ol']]) {
    h.eq(`${was} is left alone`, await name(id), was);
  }
  h.eq('the three names are held for Antic until 2999',
    await h.q(`select name_key, user_id = $1 mine, until = '2999-12-31 00:00+00' forever from username_holds order by 1`, [ANTIC]),
    [{ name_key: 'a8', mine: true, forever: true }, { name_key: 'b6', mine: true, forever: true }, { name_key: 'g1', mine: true, forever: true }]);
  h.eq('one mod_log row per account',
    (await h.q(`select target_id from mod_log where action = 'username_takeover' and actor = $1`, [ANTIC])).length, 3);

  await h.ok('529 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('a second run changes nothing', (await h.q(`select 1 from mod_log where action = 'username_takeover'`)).length, 3);

  // Nobody else can take a held name, at sign-up or by renaming.
  const user = await h.signup('user@test.dev', 'someone');
  await h.as(user);
  let msg = null;
  try { await h.db.query(`update profiles set username = 'a8' where id = $1`, [user]); } catch (e) { msg = e.message; }
  // (246's guard says "That username is taken"; the live text from 331/480 adds the date, which reads 2999-12-31.)
  h.eq('a user can\'t rename to a held name', msg, 'That username is taken');
  const fresh = await h.signup('new@test.dev', 'b6');
  await h.admin();
  await h.ok('a sign-up asking for a held name gets another one', async () => {
    if ((await name(fresh)).toLowerCase() === 'b6') throw new Error('got b6');
  });
}
