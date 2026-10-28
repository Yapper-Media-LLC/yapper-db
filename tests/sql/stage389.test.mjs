// 389: one decoration instead of two. profile_effect merges into avatar_deco ('fx:' prefix for the CSS rings),
// community_decos.kind stays (default 'deco', old tabs read it), submit loses its kind argument, my_deco_wearers reads the one column.
// Builds on 345 + 360 with the same stand-ins.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage345.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const MORE = `
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language sql as $$ select $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(mig('345_community_decos.sql'));
  await h.db.exec(mig('360_artist_badge.sql'));
  const MIG = mig('389_one_decoration.sql');

  const art = await h.signup('art@test.dev', 'artist');
  const fan = await h.signup('fan@test.dev', 'fan');
  const fan2 = await h.signup('fan2@test.dev', 'fan2');
  const fan3 = await h.signup('fan3@test.dev', 'fan3');
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'community_decos'`);
  const ok = async (p) => { await h.admin(); await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [p]); };

  // ---------- the data move ----------
  // Only an effect: moves over with the fx: prefix. Both: the decoration wins. A community effect key 'c:' moves
  // as it is. And the column is gone.
  await h.as(fan);
  await h.q(`update profiles set avatar_deco = null, profile_effect = 'glow' where id = $1`, [fan]);
  await h.as(fan2);
  await h.q(`update profiles set avatar_deco = 'crown', profile_effect = 'rainbow' where id = $1`, [fan2]);
  await ok(`${art}/1.gif`);
  await h.as(art);
  // Pre-389 (345+360) API while seeding: three args, with a kind.
  const d1 = (await h.one(`select submit_community_deco($1, $2, $3) id`, ['effect', 'Wiggle', `${art}/1.gif`])).id;
  await h.admin();
  // review needs staff; grant mod
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  await h.admin(); await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [`${art}/1.gif`]);
  await h.as(mod);
  await h.q(`select review_community_deco($1, 'approved', '')`, [d1]);
  await h.as(fan3);
  await h.q(`update profiles set avatar_deco = null, profile_effect = $1 where id = $2`, [`c:${art}/1.gif`, fan3]);

  await h.admin();
  await h.ok('389 applies over those rows', () => h.db.exec(MIG));
  await h.ok('389 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('effect-only moved to fx:', (await h.one(`select avatar_deco from profiles where id = $1`, [fan])).avatar_deco, 'fx:glow');
  h.eq('both: the decoration stays', (await h.one(`select avatar_deco from profiles where id = $1`, [fan2])).avatar_deco, 'crown');
  h.eq('community effect moved as itself', (await h.one(`select avatar_deco from profiles where id = $1`, [fan3])).avatar_deco, `c:${art}/1.gif`);
  // The columns stay for old tabs and the bootstrap/message functions (a later migration drops them); emptied.
  h.eq('profile_effect emptied', (await h.one(`select count(*)::int n from profiles where profile_effect is not null`)).n, 0);
  h.eq('backup kept the old values', (await h.one(`select profile_effect from deco_backup_389 where id = $1`, [fan2])).profile_effect, 'rainbow');

  // ---------- what a profile may wear ----------
  await h.as(fan);
  await h.ok('plain picture key', () => h.q(`update profiles set avatar_deco = 'hearts' where id = $1`, [fan]));
  await h.ok('fx: side of the same name', () => h.q(`update profiles set avatar_deco = 'fx:hearts' where id = $1`, [fan]));
  await h.ok('a css ring effect', () => h.q(`update profiles set avatar_deco = 'fx:glow' where id = $1`, [fan]));
  await h.fails('unknown plain key', `update profiles set avatar_deco = 'chris' where id = $1`, [fan]);
  await h.fails('unknown fx key', `update profiles set avatar_deco = 'fx:nope' where id = $1`, [fan]);
  await h.fails('community path must be approved', `update profiles set avatar_deco = 'c:${art}/nope.png' where id = $1`, [fan]);
  await h.ok('the approved community one', () => h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/1.gif`, fan]));

  // ---------- artists: one flow, no kind ----------
  await ok(`${art}/3.png`);
  await h.as(art);
  await h.fails('the old 3-arg signature is gone', `select submit_community_deco('deco', 'X', $1)`, [`${art}/3.png`]);

  // ---------- wearers ----------
  await h.admin(); await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [`${art}/2.png`]);
  await h.as(art);
  const d2 = (await h.one(`select submit_community_deco($1, $2) id`, ['Second', `${art}/2.png`])).id;
  h.eq('new rows default kind to deco', (await h.one(`select kind from community_decos where id = $1`, [d2])).kind, 'deco');
  await h.as(mod);
  await h.q(`select review_community_deco($1, 'approved', '')`, [d2]);
  await h.as(fan2);
  await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/2.png`, fan2]);
  await h.as(fan3);
  await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/2.png`, fan3]);
  await h.as(art);
  h.eq('wear counts from the one column', (await h.one(`select my_deco_wearers() w`)).w, {
    [`${art}/1.gif`]: 1, // fan, kept from the old world
    [`${art}/2.png`]: 2, // fan2 + fan3
  });

  // ---------- unwear ----------
  await h.as(mod);
  await h.q(`select review_community_deco($1, 'removed', 'taken down')`, [d1]);
  await h.admin();
  h.eq('unwear cleared it everywhere', (await h.one(`select count(*) n from profiles where avatar_deco = $1`, [`c:${art}/1.gif`])).n, 0);
}
