// 678: name banners (flag name_banners). Runs 672 first (its stand-ins and live pieces), then 678 on top.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';
import { MORE } from './stage634.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const read = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const M672 = read('672_community_effects.sql');
const MIG = read('678_name_banners.sql');
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
    if (MIG.toLowerCase().includes(bad)) throw new Error(`678 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(LIVE);
  await h.db.exec(M672);
  await h.q(`insert into feature_flags (key, label, mode) values ('community_decos', 'x', 'everyone') on conflict (key) do nothing`);

  await h.ok('678 runs', () => h.db.exec(MIG));
  await h.ok('678 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag in test', (await h.one(`select mode, users, servers from feature_flags where key = 'name_banners'`)),
    { mode: 'test', users: ['00000000-0000-4000-8000-00000000a001'], servers: ['00000000-0000-4000-8000-00000000b001'] });
  h.eq('one submit function', (await h.one(`select count(*)::int n from pg_proc where proname = 'submit_community_deco'`)).n, 1);

  const artist = await h.signup('artist@test.dev', 'artist');
  const tester = await h.signup('tester@test.dev', 'tester');
  const out = await h.signup('out@test.dev', 'outsider');
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid || $2::uuid where key in ('name_banners', 'community_effects')`, [artist, tester]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);

  // Built-in ones: behind the flag, known keys only.
  await h.as(out);
  h.eq('outsider cannot wear a built-in', await err(`update profiles set name_banner = 'aurora' where id = $1`, [out]), "Name banners aren't available yet");
  h.eq('outsider cannot send a banner', await err(`select submit_community_deco('Strip', $1 || '/r2-s.png', null, 'banner')`, [out]), 'Not available yet');
  await h.as(tester);
  h.eq('wear a built-in', await err(`update profiles set name_banner = 'aurora' where id = $1`, [tester]), 'ok');
  h.eq('unknown key refused', await err(`update profiles set name_banner = 'rainbowz' where id = $1`, [tester]), 'Unknown name banner');
  h.eq('p: refused', await err(`update profiles set name_banner = 'p:x/y.png' where id = $1`, [tester]), 'Unknown name banner');
  h.eq('others can read it', (await h.one(`select name_banner from profiles where id = $1`, [tester])).name_banner, 'aurora');
  h.eq('cannot set someone else\'s', (await h.q(`update profiles set name_banner = 'ocean' where id = $1 returning id`, [artist])).length, 0);

  // Sending one in: its own count, no events.
  await h.as(artist);
  h.eq('no events for banners', await err(`select submit_community_deco('Boo', $1 || '/r2-b.png', 'halloween_2026', 'banner')`, [artist]), 'Events take decorations only');
  const nb = (await h.one(`select submit_community_deco('Waves', $1 || '/r2-waves.png', null, 'banner') id`, [artist])).id;
  const fx = (await h.one(`select submit_community_deco('Sparks', $1 || '/r2-sparks.webp', null, 'profile') id`, [artist])).id;
  const deco = (await h.one(`select submit_community_deco('Crown', $1 || '/r2-crown.png') id`, [artist])).id;
  h.eq('kinds stored', (await h.q(`select kind from community_decos where id in ($1, $2, $3) order by name`, [deco, fx, nb])).map((r) => r.kind), ['deco', 'profile', 'banner']);
  await h.ok('waiting caps counted per kind', async () => {
    await h.q(`select submit_community_deco('Nb2', $1 || '/r2-n2.png', null, 'banner')`, [artist]);
    await h.q(`select submit_community_deco('Nb3', $1 || '/r2-n3.png', null, 'banner')`, [artist]);
    await h.q(`select submit_community_deco('Deco2', $1 || '/r2-d2.png')`, [artist]);
    await h.q(`select submit_community_deco('Deco3', $1 || '/r2-d3.png')`, [artist]);
  });
  h.eq('fourth waiting banner refused', await err(`select submit_community_deco('Nb4', $1 || '/r2-n4.png', null, 'banner')`, [artist]), 'You have 3 waiting for review already. Wait for those first.');
  h.eq('fourth waiting decoration refused', await err(`select submit_community_deco('Deco4', $1 || '/r2-d4.png')`, [artist]), 'You have 3 waiting for review already. Wait for those first.');

  await h.admin();
  await h.q(`update community_decos set status = 'approved' where id in ($1, $2, $3)`, [nb, fx, deco]);
  const path = async (id) => (await h.one(`select path from community_decos where id = $1`, [id])).path;
  const nbPath = await path(nb);
  const fxPath = await path(fx);
  const decoPath = await path(deco);

  // Wearing a community one, each kind in its own slot.
  await h.as(tester);
  h.eq('wear the banner', await err(`update profiles set name_banner = 'c:' || $1 where id = $2`, [nbPath, tester]), 'ok');
  h.eq('a decoration is not a banner', await err(`update profiles set name_banner = 'c:' || $1 where id = $2`, [decoPath, tester]), "That name banner isn't available");
  h.eq('an effect is not a banner', await err(`update profiles set name_banner = 'c:' || $1 where id = $2`, [fxPath, tester]), "That name banner isn't available");
  h.eq('a banner is not an avatar decoration', await err(`update profiles set avatar_deco = 'c:' || $1 where id = $2`, [nbPath, tester]), "That decoration isn't available");
  h.eq('a banner is not a profile effect', await err(`update profiles set profile_effect = 'p:' || $1 where id = $2`, [nbPath, tester]), "That profile effect isn't available");
  h.eq('decoration still wears', await err(`update profiles set avatar_deco = 'c:' || $1 where id = $2`, [decoPath, tester]), 'ok');
  // Priced: buy first.
  await h.admin();
  await h.q(`update community_decos set price = 100 where id = $1`, [nb]);
  await h.q(`update profiles set name_banner = null where id = $1`, [tester]);
  await h.as(tester);
  h.eq('priced banner needs buying', await err(`update profiles set name_banner = 'c:' || $1 where id = $2`, [nbPath, tester]), 'Buy that name banner first');
  await h.as(artist);
  h.eq('the artist wears their own priced one', await err(`update profiles set name_banner = 'c:' || $1 where id = $2`, [nbPath, artist]), 'ok');
  await h.admin();
  await h.q(`insert into deco_owned values ($1, $2, 100)`, [tester, nb]);
  await h.as(tester);
  h.eq('bought, it wears', await err(`update profiles set name_banner = 'c:' || $1 where id = $2`, [nbPath, tester]), 'ok');
  h.eq('other edits pass with it on', await err(`update profiles set avatar_deco = null where id = $1`, [tester]), 'ok');
  await h.as(out);
  h.eq('outside the flag, taking it off works', await err(`update profiles set name_banner = null where id = $1`, [out]), 'ok');

  // Counts and order.
  await h.as(artist);
  const w = (await h.one(`select my_deco_wearers() j`)).j;
  h.eq('wearers count banners', w[nbPath], 2);
  h.eq('popular banners only list banners', (await h.q(`select name, wearers from community_decos_popular(0, 200, 'banner')`)), [{ name: 'Waves', wearers: 2 }]);
  h.eq('popular decorations leave banners out', (await h.q(`select name from community_decos_popular(0, 200)`)).map((r) => r.name), ['Crown']);
  h.eq('popular effects leave banners out', (await h.q(`select name from community_decos_popular(0, 200, 'profile')`)).map((r) => r.name), ['Sparks']);

  // Taking it down takes it off everyone; built-in wearers keep theirs.
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'name_banners'`, [out]);
  await h.as(out);
  await h.q(`update profiles set name_banner = 'galaxy' where id = $1`, [out]);
  await h.admin();
  await h.q(`truncate rt_changed`);
  await h.q(`select community_deco_unwear($1)`, [nbPath]);
  h.eq('banner off both wearers', (await h.one(`select count(*)::int n from profiles where name_banner like 'c:%'`)).n, 0);
  h.eq('built-in kept', (await h.one(`select name_banner from profiles where id = $1`, [out])).name_banner, 'galaxy');
  h.eq('realtime told', (await h.one(`select count(distinct id)::int n from rt_changed`)).n, 2);
}
