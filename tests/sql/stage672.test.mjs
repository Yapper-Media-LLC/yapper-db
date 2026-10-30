// 672: community profile effects (flag community_effects). 537's stand-ins, 634's community_decos stand-in, plus the
// columns, triggers and tables the live deco pieces use (event, path_key, deco_owned, the two profile triggers).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';
import { MORE } from './stage634.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '672_community_effects.sql'), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const LIVE = `
alter table public.community_decos add column if not exists event text;
alter table public.community_decos alter column kind drop not null;
alter table public.community_decos add constraint community_decos_kind_check check (kind in ('deco', 'effect'));
create unique index if not exists community_decos_path_key on public.community_decos (path);
alter table public.profiles add column if not exists avatar_deco text;
alter table public.profiles add column if not exists profile_effect text;
grant update (avatar_deco, profile_effect) on public.profiles to authenticated;
create table if not exists public.deco_owned (user_id uuid, deco_id uuid, price_paid int, primary key (user_id, deco_id));
create table if not exists public.rt_changed (id uuid);
create or replace function public.rt_profile_changed(ids uuid[]) returns void language sql as $$ insert into public.rt_changed select unnest(ids) $$;
create or replace function public.profile_effect_plus_only() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger profile_effect_plus_only before update of profile_effect on public.profiles for each row execute function public.profile_effect_plus_only();
create or replace function public.profile_cosmetics_ok() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger profile_cosmetics_ok before insert or update of avatar_deco on public.profiles for each row execute function public.profile_cosmetics_ok();
`;

export default async function (h) {
  for (const bad of ['drop ', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`672 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(LIVE);
  await h.q(`insert into feature_flags (key, label, mode) values ('community_decos', 'x', 'everyone') on conflict (key) do nothing`);

  await h.ok('672 runs', () => h.db.exec(MIG));
  await h.ok('672 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag in test', (await h.one(`select mode from feature_flags where key = 'community_effects'`)).mode, 'test');
  h.eq('one submit function', (await h.one(`select count(*)::int n from pg_proc where proname = 'submit_community_deco'`)).n, 1);
  h.eq('one popular function', (await h.one(`select count(*)::int n from pg_proc where proname = 'community_decos_popular'`)).n, 1);

  const artist = await h.signup('artist@test.dev', 'artist');
  const tester = await h.signup('tester@test.dev', 'tester');
  const out = await h.signup('out@test.dev', 'outsider');
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`update feature_flags set users = users || $1::uuid || $2::uuid where key = 'community_effects'`, [artist, tester]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);

  // Sending in: behind the flag, its own count, no events.
  await h.as(out);
  h.eq('outsider cannot send an effect', await err(`select submit_community_deco('Sparks', $1 || '/r2-a.webp', null, 'profile')`, [out]), 'Not available yet');
  h.eq('outsider still sends decorations', await err(`select submit_community_deco('Hat', $1 || '/r2-hat.png')`, [out]), 'ok');
  await h.as(artist);
  h.eq('unknown kind refused', await err(`select submit_community_deco('Odd', $1 || '/r2-o.png', null, 'banner')`, [artist]), 'Unknown kind');
  h.eq('no events for effects', await err(`select submit_community_deco('Boo', $1 || '/r2-b.webp', 'halloween_2026', 'profile')`, [artist]), 'Events take decorations only');
  const fx = (await h.one(`select submit_community_deco('Sparks', $1 || '/r2-sparks.webp', null, 'profile') id`, [artist])).id;
  const deco = (await h.one(`select submit_community_deco('Crown', $1 || '/r2-crown.png') id`, [artist])).id;
  h.eq('kinds stored', (await h.q(`select kind from community_decos where id in ($1, $2) order by name`, [deco, fx])).map((r) => r.kind), ['deco', 'profile']);
  await h.ok('waiting caps counted per kind', async () => {
    await h.q(`select submit_community_deco('Fx2', $1 || '/r2-f2.webp', null, 'profile')`, [artist]);
    await h.q(`select submit_community_deco('Fx3', $1 || '/r2-f3.webp', null, 'profile')`, [artist]);
    await h.q(`select submit_community_deco('Deco2', $1 || '/r2-d2.png')`, [artist]);
  });
  h.eq('fourth waiting effect refused', await err(`select submit_community_deco('Fx4', $1 || '/r2-f4.webp', null, 'profile')`, [artist]), 'You have 3 waiting for review already. Wait for those first.');

  // Approve both (as the table owner, the review function is a stand-in here).
  await h.admin();
  await h.q(`update community_decos set status = 'approved' where id in ($1, $2)`, [fx, deco]);
  const fxPath = (await h.one(`select path from community_decos where id = $1`, [fx])).path;
  const decoPath = (await h.one(`select path from community_decos where id = $1`, [deco])).path;

  // Wearing.
  await h.as(tester);
  h.eq('wear the effect', await err(`update profiles set profile_effect = 'p:' || $1 where id = $2`, [fxPath, tester]), 'ok');
  h.eq('a decoration is not a profile effect', await err(`update profiles set profile_effect = 'p:' || $1 where id = $2`, [decoPath, tester]), "That profile effect isn't available");
  h.eq('an effect is not an avatar decoration', await err(`update profiles set avatar_deco = 'c:' || $1 where id = $2`, [fxPath, tester]), "That decoration isn't available");
  h.eq('the decoration still wears', await err(`update profiles set avatar_deco = 'c:' || $1 where id = $2`, [decoPath, tester]), 'ok');
  h.eq('c: in profile_effect refused', await err(`update profiles set profile_effect = 'c:' || $1 where id = $2`, [decoPath, tester]), 'Unknown profile effect');
  h.eq('old built-in key still accepted', await err(`update profiles set profile_effect = 'glow' where id = $1`, [tester]), 'ok');
  h.eq('other edits pass with a stale value', await err(`update profiles set avatar_deco = null where id = $1`, [tester]), 'ok');
  await h.q(`update profiles set profile_effect = 'p:' || $1, avatar_deco = 'c:' || $2 where id = $3`, [fxPath, decoPath, tester]);
  // Priced: buy first.
  await h.admin();
  await h.q(`update community_decos set price = 100 where id = $1`, [fx]);
  await h.q(`update profiles set profile_effect = null where id = $1`, [tester]);
  await h.as(tester);
  h.eq('priced effect needs buying', await err(`update profiles set profile_effect = 'p:' || $1 where id = $2`, [fxPath, tester]), 'Buy that profile effect first');
  await h.as(artist);
  h.eq('the artist wears their own priced one', await err(`update profiles set profile_effect = 'p:' || $1 where id = $2`, [fxPath, artist]), 'ok');
  await h.admin();
  await h.q(`insert into deco_owned values ($1, $2, 100)`, [tester, fx]);
  await h.as(tester);
  h.eq('bought, it wears', await err(`update profiles set profile_effect = 'p:' || $1 where id = $2`, [fxPath, tester]), 'ok');
  await h.as(out);
  h.eq('outside the flag, no wearing', await err(`update profiles set profile_effect = 'p:' || $1 where id = $2`, [fxPath, out]), "Profile effects aren't available yet");
  h.eq('outside the flag, taking it off works', await err(`update profiles set profile_effect = null where id = $1`, [out]), 'ok');

  // Counts and order.
  await h.as(artist);
  const w = (await h.one(`select my_deco_wearers() j`)).j;
  h.eq('wearers: effect and decoration', [w[fxPath], w[decoPath]], [2, 1]);
  h.eq('popular effects only list effects', (await h.q(`select name, wearers from community_decos_popular(0, 200, 'profile')`)), [{ name: 'Sparks', wearers: 2 }]);
  h.eq('popular decorations leave effects out', (await h.q(`select name from community_decos_popular(0, 200)`)).map((r) => r.name), ['Crown']);
  await h.as(null);
  h.eq('anon cannot call popular', await err(`select * from community_decos_popular(0, 200, 'profile')`), 'permission denied for function community_decos_popular');

  // Taking it down takes it off everyone, the decoration stays.
  await h.admin();
  await h.q(`select community_deco_unwear($1)`, [fxPath]);
  h.eq('effect off both wearers', (await h.one(`select count(*)::int n from profiles where profile_effect is not null`)).n, 0);
  h.eq('decoration still worn', (await h.one(`select avatar_deco from profiles where id = $1`, [tester])).avatar_deco, `c:${decoPath}`);
  h.eq('realtime told', (await h.one(`select count(distinct id)::int n from rt_changed`)).n, 2);
  await h.q(`select community_deco_unwear($1)`, [decoPath]);
  h.eq('decoration off too', (await h.one(`select avatar_deco from profiles where id = $1`, [tester])).avatar_deco, null);
  void mod;
}
