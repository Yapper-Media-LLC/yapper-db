// 609: no_slurs() checks only the columns an UPDATE changes. Same base as 277 (001..024, flags 031/041, stand-ins for
// what mod_reset_profile touches), then 246 + 277 (the reset), then 609. The bug: resetting only the username of
// someone whose bio also held a slur failed, because the reset's UPDATE lists bio and the trigger rechecked it.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists banner_path text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists pronouns text;
alter table public.profiles add column if not exists links jsonb;
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
create or replace function public.mod_guard(act text, uid uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
end $$;
`;

const SLUR = /contains a slur/;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(mig('246_username_holds.sql'));
  await h.db.exec(mig('277_mod_reset_holds_name.sql'));

  const refused = async (name, sql, params) => {
    let m = null;
    try { await h.db.query(sql, params); } catch (e) { m = e.message; }
    if (!m || !SLUR.test(m)) throw new Error(`✗ ${name}: expected ${SLUR}, got ${m ?? 'success'}`);
    h.passed++;
  };

  const mod = await h.signup('mod@test.dev', 'mod');
  const bad = await h.signup('bad@test.dev', 'badguy');
  const bad2 = await h.signup('bad2@test.dev', 'badguy2');
  const user = await h.signup('user@test.dev', 'user');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  // Slurs that got in before the filter knew them (or another way round it): seeded with the trigger off.
  await h.db.exec(`alter table profiles disable trigger profiles_no_slurs`);
  for (const id of [bad, bad2]) await h.q(`update profiles set username = 'retard_' || substr($1::text, 1, 4), bio = 'what a retard', display_name = 'retard' where id = $1`, [id]);
  await h.db.exec(`alter table profiles enable trigger profiles_no_slurs`);

  // Before 609: the reported failure.
  await h.as(mod);
  await refused('before 609, a username-only reset fails over the bio', `select mod_reset_profile($1, array['display_name', 'username'], 'Offensive name')`, [bad]);

  await h.admin();
  await h.db.exec(mig('609_no_slurs_changed_only.sql'));
  await h.ok('609 re-runs cleanly', () => h.db.exec(mig('609_no_slurs_changed_only.sql')));

  await h.as(mod);
  await h.ok('mod resets name + display name, bio left alone', () =>
    h.q(`select mod_reset_profile($1, array['display_name', 'username'], 'Offensive name')`, [bad]));
  await h.admin();
  const p = await h.one(`select username, display_name, bio from profiles where id = $1`, [bad]);
  h.eq('name reset, bio untouched', { u: /^user[0-9a-f]{8}$/.test(p.username), d: p.display_name, b: p.bio }, { u: true, d: null, b: 'what a retard' });
  const log = await h.one(`select reason from mod_log where action = 'profile_reset' and target_id = $1`, [bad]);
  h.eq('log holds no old name', /retard/.test(log.reason), false);

  await h.as(mod);
  await h.ok('mod resets everything at once', () =>
    h.q(`select mod_reset_profile($1, array['username', 'bio', 'display_name'], 'Offensive name')`, [bad2]));

  // The filter still applies to anything new or edited.
  await h.as(user);
  await refused('slur bio still refused', `update profiles set bio = 'retard' where id = $1`, [user]);
  await refused('slur username still refused', `update profiles set username = 'retard' where id = $1`, [user]);
  await h.as(bad);
  await refused('bio edited to another slur refused', `update profiles set bio = 'you retard' where id = $1`, [bad]);
  await h.ok('unrelated edit with an old slur bio goes through', () => h.q(`update profiles set username = 'cleanname' where id = $1`, [bad]));
  await h.ok('rewriting the same bio is not new text', () => h.q(`update profiles set bio = bio where id = $1`, [bad]));

  // Other tables share the function.
  await h.as(user);
  const sid = (await h.one(`select create_server('Fine', null) id`)).id;
  const ch = (await h.one(`select id from channels where server_id = $1 and name = 'general'`, [sid])).id;
  await refused('slur message refused', `insert into messages (channel_id, author_id, content) values ($1, $2, 'retard')`, [ch, user]);
  const m = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hello') returning id`, [ch, user])).id;
  await refused('slur edit refused', `update messages set content = 'retard' where id = $1`, [m]);
}
