// 360: Artist badge (first approval), 6 waiting for artists, wear counts, admins can hand out the badge.
// Builds on 345 with the same stand-ins.
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
  const MIG = mig('360_artist_badge.sql');
  await h.db.exec(MIG);
  await h.ok('360 re-runs cleanly', () => h.db.exec(MIG));

  const art = await h.signup('art@test.dev', 'artist');
  const fan = await h.signup('fan@test.dev', 'fan');
  const mod = await h.signup('mod@test.dev', 'mod');
  const boss = await h.signup('boss@test.dev', 'boss');
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  await h.q(`insert into site_admins values ($1)`, [boss]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'community_decos'`);
  const ok = async (p) => { await h.admin(); await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [p]); };
  const submit = async (who, kind, name, path) => { await ok(path); await h.as(who); return (await h.one(`select submit_community_deco($1, $2, $3) id`, [kind, name, path])).id; };
  const badges = async (who) => { await h.admin(); return (await h.one(`select badges from profiles where id = $1`, [who])).badges; };

  const d1 = await submit(art, 'deco', 'One', `${art}/1.png`);
  await submit(art, 'deco', 'Two', `${art}/2.png`);
  const e1 = await submit(art, 'effect', 'Three', `${art}/3.gif`);
  await ok(`${art}/4.png`);
  await h.as(art);
  await h.fails('not an artist yet: 3 waiting is the most', `select submit_community_deco('deco', 'Four', $1)`, [`${art}/4.png`]);
  h.eq('no badge before an approval', await badges(art), []);

  await h.as(mod);
  await h.q(`select review_community_deco($1, 'approved', '')`, [d1]);
  h.eq('first approval: Artist badge', await badges(art), ['artist']);
  await h.admin();
  h.eq('logged as automatic', (await h.q(`select action, reason from mod_log where action = 'badge_auto'`)).map((r) => [r.action, r.reason]), [['badge_auto', 'artist']]);
  await h.as(mod);
  await h.q(`select review_community_deco($1, 'approved', '')`, [e1]);
  h.eq('a second approval doesn\'t add it twice', await badges(art), ['artist']);
  await h.admin();
  h.eq('and isn\'t logged twice', (await h.q(`select 1 from mod_log where action = 'badge_auto'`)).length, 1);

  // Artists: 6 waiting.
  // "Two" is still waiting: with 5 more that's 6.
  for (const n of [4, 5, 6, 7, 8]) await submit(art, 'deco', `D${n}`, `${art}/${n}.png`);
  await ok(`${art}/9.png`);
  await h.as(art);
  await h.fails('an artist: 6 waiting is the most', `select submit_community_deco('deco', 'Nine', $1)`, [`${art}/9.png`]);

  // Wear counts, only for the artist's own.
  await h.as(fan);
  await h.q(`update profiles set avatar_deco = $1, profile_effect = $2 where id = $3`, [`c:${art}/1.png`, `c:${art}/3.gif`, fan]);
  await h.as(mod);
  await h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/1.png`, mod]);
  await h.as(art);
  h.eq('the artist sees how many wear each', (await h.one(`select my_deco_wearers() w`)).w, { [`${art}/1.png`]: 2, [`${art}/3.gif`]: 1 });
  await h.as(fan);
  h.eq('others see only their own (none)', (await h.one(`select my_deco_wearers() w`)).w, {});

  // Re-approving an approved one doesn't hand back a badge an admin took away.
  await h.as(boss); await h.q(`select admin_set_badge($1, 'artist', false)`, [art]);
  await h.as(mod);
  await h.ok('re-approving an approved one', () => h.q(`select review_community_deco($1, 'approved', '')`, [d1]));
  h.eq('badge stays off', await badges(art), []);

  // A profile the guards won't save: the approval still goes through, just without the badge.
  const odd = await h.signup('odd@test.dev', 'oddone');
  await h.admin();
  await h.db.exec(`create or replace function public.refuse_odd() returns trigger language plpgsql as $f$ begin if new.username = 'oddone' then raise exception 'That display name isn''t allowed'; end if; return new; end $f$;
    create trigger refuse_odd before update on public.profiles for each row execute function public.refuse_odd();`);
  const o1 = await submit(odd, 'deco', 'Odd', `${odd}/1.png`);
  await h.as(mod);
  await h.ok('approval goes through for a profile that won\'t save', () => h.q(`select review_community_deco($1, 'approved', '')`, [o1]));
  await h.admin();
  h.eq('approved', (await h.one(`select status from community_decos where id = $1`, [o1])).status, 'approved');
  h.eq('no badge, no crash', await badges(odd), []);
  await h.db.exec(`drop trigger refuse_odd on public.profiles`);

  // Banned artists don't get it.
  const ban = await h.signup('ban@test.dev', 'banme');
  const b1 = await submit(ban, 'deco', 'Banned', `${ban}/1.png`);
  await h.admin(); await h.q(`insert into banned values ($1)`, [ban]);
  await h.as(mod); await h.q(`select review_community_deco($1, 'approved', '')`, [b1]);
  h.eq('banned: no badge', await badges(ban), []);

  // Admins can hand it out and take it away; mods can't.
  await h.as(mod);
  await h.fails('a mod can\'t give the Artist badge', `select admin_set_badge($1, 'artist', true)`, [fan]);
  await h.as(boss);
  await h.ok('an admin can', () => h.q(`select admin_set_badge($1, 'artist', true)`, [fan]));
  h.eq('fan has it', await badges(fan), ['artist']);
  await h.as(boss);
  await h.ok('and take it back', () => h.q(`select admin_set_badge($1, 'artist', false)`, [fan]));
  h.eq('gone', await badges(fan), []);
}
