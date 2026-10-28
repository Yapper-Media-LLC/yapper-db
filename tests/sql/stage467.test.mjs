// 467: a Last.fm link only shows to others (and only counts for matching) once it was made through Last.fm's
// sign-in (verified). Typed-in links from before stay their owner's alone; one verified Last.fm account per user.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '112_member_count_column.sql'];

export default async function (h) {
  await h.admin();
  for (const f of ['447_steam_link.sql', '450_steam_prefs.sql', '457_media_connections.sql', '458_links_rls_scope.sql',
    '459_interest_matches.sql', '461_match_compute_bounded.sql']) await h.db.exec(mig(f));

  const names = ['me', 'faker', 'real', 'old', 'anime'];
  const u = {};
  for (const n of names) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  await h.q(`update feature_flags set users = $1 where key = 'interest_matches'`, [Object.values(u)]);
  // Everyone shares a server, so they may read each other's links.
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [u.me])).id;
  for (const n of names) await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, u[n]]);

  const svc = () => h.db.exec(`set role service_role`);
  await svc();
  // Before 467: faker typed "tobyfox", old typed their own name, anime linked AniList. All rows have no verified.
  await h.q(`insert into media_links (user_id, source, account_id, handle) values ($1, 'lastfm', 'tobyfox', 'tobyfox'), ($2, 'lastfm', 'oldie', 'oldie'), ($3, 'anilist', '77', 'a')`, [u.faker, u.old, u.anime]);
  await h.db.exec(`reset role`);

  const MIG = mig('467_lastfm_verified.sql');
  await h.ok('467 runs', () => h.db.exec(MIG));
  await h.ok('467 re-runs cleanly', () => h.db.exec(MIG));
  await h.admin();
  h.eq('no existing row changed', (await h.one(`select count(*)::int n from media_links where verified is not null`)).n, 0);
  h.eq('match_compute patched once', (await h.one(`select (length(prosrc) - length(replace(prosrc, '467:', ''))) / 4 n from pg_proc where proname = 'match_compute'`)).n, 1);
  h.eq('match_compute still service_role only', (await h.one(`select has_function_privilege('authenticated', 'match_compute(uuid, int)', 'execute') ok`)).ok, false);
  h.eq('interest_ok still service_role only', (await h.one(`select has_function_privilege('authenticated', 'interest_ok(uuid, text)', 'execute') ok`)).ok, false);

  // Reading: typed-in Last.fm rows are their owner's alone; AniList rows without verified still show.
  await h.as(u.me);
  const seen = async () => (await h.q(`select user_id, source from media_links order by source`)).map((r) => `${names.find((n) => u[n] === r.user_id)}:${r.source}`).sort();
  h.eq('others see only the AniList link', await seen(), ['anime:anilist']);
  await h.as(u.faker);
  h.eq('the owner still sees their typed-in link', (await h.q(`select 1 from media_links where user_id = $1`, [u.faker])).length, 1);
  await h.fails('users still can’t set verified', `update media_links set verified = true where user_id = $1`, [u.faker]);

  // The real tobyfox signs in: allowed although faker's typed row has the same name, and it shows.
  await svc();
  await h.q(`insert into media_links (user_id, source, account_id, handle, verified) values ($1, 'lastfm', 'tobyfox', 'tobyfox', true)`, [u.real]);
  await h.fails('a second verified link of the same Last.fm account is refused', `update media_links set verified = true where user_id = $1 and source = 'lastfm'`, [u.faker]);
  // old re-links the same account through sign-in.
  await h.q(`update media_links set verified = true where user_id = $1 and source = 'lastfm'`, [u.old]);
  await h.db.exec(`reset role`);
  await h.as(u.me);
  h.eq('verified Last.fm links show', await seen(), ['anime:anilist', 'old:lastfm', 'real:lastfm']);

  // Matching: me and faker "share" an artist through faker's typed-in tobyfox; it must count for nobody.
  await svc();
  await h.q(`insert into media_links (user_id, source, account_id, handle, verified) values ($1, 'lastfm', 'mine', 'mine', true)`, [u.me]);
  const ART = JSON.stringify([{ kind: 'artist', item_id: 'toby fox', title: 'Toby Fox', weight: 1 }]);
  for (const [n, acc] of [['me', 'mine'], ['faker', 'tobyfox'], ['real', 'tobyfox']]) {
    await h.q(`select media_save_refresh($1, 'lastfm', $2, '{}', $3)`, [u[n], acc, ART]);
  }
  h.eq('interest_ok: typed-in Last.fm no', (await h.one(`select interest_ok($1, 'lastfm') ok`, [u.faker])).ok, false);
  h.eq('interest_ok: signed-in Last.fm yes', (await h.one(`select interest_ok($1, 'lastfm') ok`, [u.real])).ok, true);
  h.eq('interest_ok: AniList without verified yes', (await h.one(`select interest_ok($1, 'anilist') ok`, [u.anime])).ok, true);
  const res = (await h.one(`select match_compute($1) r`, [u.me])).r;
  const shared = (id) => res.find((x) => x.user_id === id)?.items_n ?? 0;
  h.eq('the real owner shares the artist', shared(u.real), 1);
  h.eq('the faker shares nothing', shared(u.faker), 0);
  await h.db.exec(`reset role`);

  // A changed match_compute makes the migration fail instead of silently skipping the patch.
  await h.admin();
  await h.db.exec(`create or replace function public.match_compute(p_user uuid, p_limit int default 20) returns jsonb language sql as $$ select '[]'::jsonb $$`);
  const why = await h.db.exec(MIG).then(() => 'ran', (e) => e.message);
  h.eq('467 refuses an unknown match_compute body', /467: match_compute is not 461/.test(why), true);
}
