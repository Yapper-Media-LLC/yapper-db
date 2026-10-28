// 397: Halloween event decorations. community_decos.event, submit_community_deco gains p_event (default null),
// event submissions need the halloween_decos flag, ordinary ones still need community_decos.
// Builds on 345 + 360 + 389 with the same stand-ins.
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
  await h.db.exec(mig('389_one_decoration.sql'));
  const MIG = mig('397_halloween_decos.sql');
  await h.ok('397 applies', () => h.db.exec(MIG));
  await h.ok('397 re-runs cleanly', () => h.db.exec(MIG));

  const art = await h.signup('art@test.dev', 'artist');
  const fan = await h.signup('fan@test.dev', 'fan');
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  const ok = async (p) => { await h.admin(); await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [p]); };
  for (const p of ['1.png', '2.png', '3.png', '4.png']) await ok(`${art}/${p}`);

  // ---------- flags gate each kind ----------
  await h.as(art);
  await h.fails('ordinary one: community_decos off', `select submit_community_deco('Plain', $1, null)`, [`${art}/1.png`]);
  await h.fails('event one: halloween_decos off', `select submit_community_deco('Spooky', $1, 'halloween_2026')`, [`${art}/1.png`]);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'halloween_decos'`);
  await h.as(art);
  await h.fails('ordinary one still needs its own flag', `select submit_community_deco('Plain', $1, null)`, [`${art}/1.png`]);
  await h.fails('unknown event', `select submit_community_deco('Nope', $1, 'xmas_2026')`, [`${art}/1.png`]);
  const d1 = (await h.one(`select submit_community_deco($1, $2, $3) id`, ['Spooky', `${art}/1.png`, 'halloween_2026'])).id;
  h.eq('event stored', (await h.one(`select event from community_decos where id = $1`, [d1])).event, 'halloween_2026');
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'community_decos'`);
  await h.as(art);
  const d2 = (await h.one(`select submit_community_deco($1, $2) id`, ['Plain', `${art}/2.png`])).id;
  h.eq('ordinary one has no event', (await h.one(`select event from community_decos where id = $1`, [d2])).event, null);
  const d3 = (await h.one(`select submit_community_deco($1, $2, $3) id`, ['Blank event', `${art}/3.png`, '  '])).id;
  h.eq('blank event means none', (await h.one(`select event from community_decos where id = $1`, [d3])).event, null);

  // ---------- the rest of the pipeline is unchanged ----------
  await h.fails('limit counts both kinds (3 waiting)', `select submit_community_deco('Four', $1, 'halloween_2026')`, [`${art}/4.png`]);
  await h.as(mod);
  await h.q(`select review_community_deco($1, 'approved', '')`, [d1]);
  await h.as(fan);
  await h.ok('an approved event one can be worn', () => h.q(`update profiles set avatar_deco = $1 where id = $2`, [`c:${art}/1.png`, fan]));
  h.eq('event column readable by everyone', (await h.one(`select event from community_decos where id = $1`, [d1])).event, 'halloween_2026');
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'halloween_decos'`);
  await h.as(fan);
  h.eq('event closed: still worn', (await h.one(`select avatar_deco from profiles where id = $1`, [fan])).avatar_deco, `c:${art}/1.png`);
}
