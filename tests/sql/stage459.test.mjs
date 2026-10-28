// 459: people you might click with. Steam games become interests and go with the link; the scoring favours rare
// shared items and counts servers a little; hidden, private, blocked, banned, friends, bots and opted-out people
// never show up; the cache is per user and nobody can ask for someone else's list.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '112_member_count_column.sql'];

export default async function (h) {
  await h.admin();
  for (const f of ['447_steam_link.sql', '450_steam_prefs.sql', '457_media_connections.sql', '458_links_rls_scope.sql']) await h.db.exec(mig(f));
  const MIG = mig('459_interest_matches.sql');
  await h.ok('459 runs', () => h.db.exec(MIG));
  await h.ok('459 re-runs cleanly', () => h.db.exec(MIG));
  // 461 replaces match_compute with the bounded version; everything below must hold for it.
  const MIG461 = mig('461_match_compute_bounded.sql');
  await h.ok('461 runs', () => h.db.exec(MIG461));
  await h.ok('461 re-runs cleanly', () => h.db.exec(MIG461));
  h.eq('flag interest_matches in test', (await h.one(`select mode, users from feature_flags where key = 'interest_matches'`)).mode, 'test');

  const names = ['me', 'rare', 'common', 'hidden', 'private', 'blocker', 'blocked', 'banned', 'optout', 'pal', 'mate', 'nothing', 'steamy', 'shy'];
  const u = {};
  for (const n of names) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  // Everyone with the flag: put them all in the test server's users list.
  await h.q(`update feature_flags set users = $1 where key = 'interest_matches'`, [Object.values(u)]);

  const svc = () => h.db.exec(`set role service_role`);
  const link = async (uid, source, id, pub = true, hidden = false) => {
    await h.q(`insert into media_links (user_id, source, account_id, is_public, prefs) values ($1, $2, $3, $4, $5)`, [uid, source, id, pub, JSON.stringify({ hidden })]);
  };
  const items = async (uid, source, list) => {
    await h.q(`select media_save_refresh($1, $2, $3, '{}', $4)`, [uid, source, `${source}-${uid.slice(0, 8)}`, JSON.stringify(list)]);
  };
  await svc();
  // "Rare" anime 900 is shared by me + rare only; "Naruto" 1 is shared by me + common + rare + hidden + ... (everyone).
  const NARUTO = { kind: 'anime', item_id: '1', title: 'Naruto', weight: 1 };
  const RARE = { kind: 'anime', item_id: '900', title: 'Kaiba', weight: 1 };
  for (const n of ['me', 'rare', 'common', 'hidden', 'private', 'blocker', 'blocked', 'banned', 'optout', 'pal']) {
    await link(u[n], 'anilist', `anilist-${u[n].slice(0, 8)}`, n !== 'private', n === 'hidden');
  }
  await items(u.me, 'anilist', [NARUTO, RARE, { kind: 'anime', item_id: '2', title: 'Bleach', weight: 0.5 }]);
  await items(u.rare, 'anilist', [RARE, NARUTO]);
  await items(u.common, 'anilist', [NARUTO]);
  for (const n of ['hidden', 'blocker', 'blocked', 'banned', 'optout', 'pal']) await items(u[n], 'anilist', [NARUTO, RARE]);
  // private: the link went private after the rows were written (rows stay, see 457).
  await h.q(`update media_links set is_public = true where user_id = $1`, [u.private]);
  await items(u.private, 'anilist', [NARUTO, RARE]);
  await h.q(`update media_links set is_public = false where user_id = $1`, [u.private]);
  h.eq('private rows kept', (await h.one(`select count(*)::int n from media_interests where user_id = $1`, [u.private])).n, 2);

  // Steam: me and steamy share Rust (252490); steamy's games are public, mate's are private.
  // shy: games public on Steam, but "show games" is off on the card.
  await h.q(`insert into steam_links (user_id, steam_id, persona, games_public, prefs) values ($1, '76561198000000001', 'Me', true, '{}'), ($2, '76561198000000002', 'S', true, '{}'), ($3, '76561198000000003', 'M', false, '{}'), ($4, '76561198000000004', 'Y', true, '{"show_games":false}')`, [u.me, u.steamy, u.mate, u.shy]);
  await h.q(`select steam_save_interests($1, '76561198000000004', $2)`, [u.shy, JSON.stringify([{ item_id: '252490', title: 'Rust', weight: 1 }])]);
  const GAMES = [{ item_id: '252490', title: 'Rust', weight: 0.9 }, { item_id: '730', title: 'CS2', weight: 0.3 }];
  h.eq('steam interests saved', (await h.one(`select steam_save_interests($1, '76561198000000001', $2) ok`, [u.me, JSON.stringify(GAMES)])).ok, true);
  h.eq('steam interests saved (steamy)', (await h.one(`select steam_save_interests($1, '76561198000000002', $2) ok`, [u.steamy, JSON.stringify(GAMES)])).ok, true);
  h.eq('steam interests saved (mate, private games)', (await h.one(`select steam_save_interests($1, '76561198000000003', $2) ok`, [u.mate, JSON.stringify(GAMES)])).ok, true);
  h.eq('wrong steam id saves nothing', (await h.one(`select steam_save_interests($1, '76561198000000009', $2) ok`, [u.me, JSON.stringify(GAMES)])).ok, false);
  h.eq('game rows have source steam, kind game', (await h.one(`select count(*)::int n from media_interests where user_id = $1 and source = 'steam' and kind = 'game'`, [u.me])).n, 2);
  await h.q(`select steam_save_interests($1, '76561198000000001', $2)`, [u.me, JSON.stringify([...GAMES, { item_id: 'not-an-app', title: 'x', weight: 1 }])]);
  h.eq('a bad app id is dropped', (await h.one(`select count(*)::int n from media_interests where user_id = $1 and source = 'steam'`, [u.me])).n, 2);
  await h.fails('unknown source refused', `insert into media_interests (user_id, source, kind, item_id, weight) values ($1, 'spotify', 'track', 'x', 1)`, [u.me]);
  await h.db.exec(`reset role`);

  // Relations.
  await h.admin();
  await h.q(`insert into blocks (blocker, blocked) values ($1, $2), ($3, $1)`, [u.me, u.blocked, u.blocker]);
  await h.q(`insert into site_bans (user_id) values ($1)`, [u.banned]);
  await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted')`, [u.me, u.pal]);
  await h.q(`insert into match_settings (user_id, suggest_me) values ($1, false)`, [u.optout]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Tiny', $1) returning id`, [u.mate])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4)`, [sid, u.me, u.mate, u.common]);
  const big = (await h.one(`insert into servers (name, owner_id) values ('HQ', $1) returning id`, [u.nothing])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [big, u.me, u.nothing]);
  await h.q(`update servers set member_count = 1000 where id = $1`, [big]);

  // The list.
  await h.as(u.me);
  const list = await h.one(`select my_matches() r`);
  const got = list.r.map((x) => x.user_id);
  const who = (id) => names.find((n) => u[n] === id);
  // rare: two shared anime. common: Naruto plus a small server. steamy: Rust (3 holders) and a bit of CS2.
  h.eq('rare, common, steamy, mate, nothing suggested in that order', got.map(who), ['rare', 'common', 'steamy', 'mate', 'nothing']);
  for (const n of ['hidden', 'private', 'blocker', 'blocked', 'banned', 'optout', 'pal', 'me', 'shy']) {
    h.eq(`${n} never suggested`, got.includes(u[n]), false);
  }
  const rare = list.r.find((x) => x.user_id === u.rare);
  h.eq('rare shared item first is the obscure one', rare.items[0].title, 'Kaiba');
  h.eq('rare shares 2 items', rare.items_n, 2);
  const common = list.r.find((x) => x.user_id === u.common);
  h.eq('common: Naruto plus the tiny server', [common.items.map((i) => i.title), common.servers], [['Naruto'], ['Tiny']]);
  const nothing = list.r.find((x) => x.user_id === u.nothing);
  h.eq('nothing: only HQ, still listed', [nothing.items_n, nothing.servers, nothing.servers_n], [0, ['HQ'], 1]);
  h.eq('a small server outscores HQ', list.r.find((x) => x.user_id === u.mate).score > nothing.score, true);
  const steamy = list.r.find((x) => x.user_id === u.steamy);
  h.eq('steamy: Rust and CS2', steamy.items.map((i) => i.title), ['Rust', 'CS2']);

  // Cache: a second call is served from the cache (steamy opting out is still filtered on read).
  await h.admin();
  const at = (await h.one(`select computed_at from match_cache where user_id = $1`, [u.me])).computed_at;
  await h.q(`insert into match_settings (user_id, suggest_me) values ($1, false)`, [u.steamy]);
  await h.as(u.me);
  const again = await h.one(`select my_matches() r`);
  h.eq('opted out since: gone on read', again.r.map((x) => who(x.user_id)), ['rare', 'common', 'mate', 'nothing']);
  h.eq('opted out since: their link is not readable through the stale cache', (await h.q(`select 1 from steam_links where user_id = $1`, [u.steamy])).length, 0);
  h.eq('still in the list: link readable', (await h.q(`select 1 from media_links where user_id = $1`, [u.rare])).length, 1);
  await h.admin();
  await h.q(`insert into blocks (blocker, blocked) values ($1, $2)`, [u.rare, u.me]);
  await h.as(u.me);
  h.eq('blocked you since: not readable either', (await h.q(`select 1 from media_links where user_id = $1`, [u.rare])).length, 0);
  h.eq('blocked you since: gone on read', (await h.one(`select my_matches() r`)).r.map((x) => who(x.user_id)), ['common', 'mate', 'nothing']);
  await h.admin();
  await h.q(`delete from blocks where blocker = $1`, [u.rare]);
  h.eq('not recomputed', (await h.one(`select computed_at from match_cache where user_id = $1`, [u.me])).computed_at, at);
  await h.q(`update match_cache set computed_at = now() - interval '7 hours' where user_id = $1`, [u.me]);
  await h.as(u.me);
  await h.one(`select my_matches() r`);
  await h.admin();
  h.eq('recomputed after 6 hours', (await h.one(`select computed_at > now() - interval '1 minute' ok from match_cache where user_id = $1`, [u.me])).ok, true);

  // Your list only.
  await h.as(u.rare);
  await h.fails('match_compute is not callable by a user', `select match_compute($1)`, [u.me]);
  await h.fails('match_cache is not readable by a user', `select * from match_cache`);
  await h.fails('match_settings of someone else can’t be changed', `insert into match_settings (user_id, suggest_me) values ($1, false)`, [u.me]);
  h.eq('you can only read your own match settings', (await h.q(`select user_id from match_settings`)).length, 0);
  await h.as(u.common);
  await h.ok('you can opt out', () => h.q(`insert into match_settings (user_id, suggest_me) values ($1, false) on conflict (user_id) do update set suggest_me = excluded.suggest_me`, [u.common]));
  await h.as(u.nothing);
  await h.q(`update feature_flags set users = '{}' where key = 'interest_matches'`).catch(() => undefined);
  await h.admin();
  await h.q(`update feature_flags set users = $1 where key = 'interest_matches'`, [[u.me]]);
  await h.as(u.nothing);
  await h.fails('no flag, no list', `select my_matches()`);

  // The suggestion lets you see their card's links (sees_user), a stranger's not.
  await h.as(u.me);
  h.eq('a suggested person’s media link is readable', (await h.q(`select 1 from media_links where user_id = $1`, [u.rare])).length, 1);
  await h.as(u.rare);
  h.eq('but not the other way round (no relation)', (await h.q(`select 1 from steam_links where user_id = $1`, [u.me])).length, 0);

  // Unlinking removes the interests.
  await h.as(u.steamy);
  await h.q(`delete from steam_links where user_id = $1`, [u.steamy]);
  await h.as(u.rare);
  await h.q(`delete from media_links where user_id = $1 and source = 'anilist'`, [u.rare]);
  await h.admin();
  h.eq('steam unlink removed its interests', (await h.one(`select count(*)::int n from media_interests where user_id = $1`, [u.steamy])).n, 0);
  h.eq('media unlink removed its interests', (await h.one(`select count(*)::int n from media_interests where user_id = $1`, [u.rare])).n, 0);

  // 463: backfill Steam games from the cached card, and a 5 minute Refresh.
  const fresh = await h.signup('fresh@test.dev', 'fresh');
  const closed = await h.signup('closed@test.dev', 'closed');
  await h.admin();
  const cached = JSON.stringify([{ app: 252490, name: 'Rust', hours: 200 }, { app: 730, name: 'CS2', hours: 9 }, { app: 1, name: 'Never played', hours: 0 }, { app: 'x', name: 'Bad', hours: 5 }]);
  await h.q(`insert into steam_links (user_id, steam_id, persona, games_public, games) values ($1, '76561198000000011', 'F', true, $3), ($2, '76561198000000012', 'C', false, $3)`, [fresh, closed, cached]);
  await h.q(`update steam_links set games = $2 where user_id = $1`, [u.me, cached]);
  const before = (await h.one(`select count(*)::int n from media_interests where user_id = $1 and source = 'steam'`, [u.me])).n;
  const MIG463 = mig('463_matches_backfill_refresh.sql');
  await h.ok('463 runs', () => h.db.exec(MIG463));
  await h.ok('463 re-runs cleanly', () => h.db.exec(MIG463));
  const rows = await h.q(`select item_id, title, weight from media_interests where user_id = $1 and source = 'steam' order by item_id`, [fresh]);
  h.eq('backfill: played games with a numeric app id only', rows.map((r) => r.title), ['Rust', 'CS2']);
  h.eq('backfill: 200 h weighs 1', Math.round(rows.find((r) => r.title === 'Rust').weight * 100) / 100, 1);
  h.eq('backfill: 9 h weighs less', rows.find((r) => r.title === 'CS2').weight < 0.5, true);
  h.eq('backfill: private game lists skipped', (await h.one(`select count(*)::int n from media_interests where user_id = $1`, [closed])).n, 0);
  h.eq('backfill: a list written by a refresh is kept as is', (await h.one(`select count(*)::int n from media_interests where user_id = $1 and source = 'steam'`, [u.me])).n, before);
  h.eq('backfill: saved lists marked stale', (await h.one(`select computed_at < now() - interval '6 hours' ok from match_cache where user_id = $1`, [u.me])).ok, true);
  await h.as(u.me);
  await h.one(`select my_matches() r`);
  await h.admin();
  await h.q(`update match_cache set computed_at = now() - interval '2 minutes' where user_id = $1`, [u.me]);
  await h.as(u.me);
  await h.one(`select my_matches(true) r`);
  await h.admin();
  h.eq('refresh within 5 minutes: cached', (await h.one(`select computed_at < now() - interval '1 minute' ok from match_cache where user_id = $1`, [u.me])).ok, true);
  await h.q(`update match_cache set computed_at = now() - interval '6 minutes' where user_id = $1`, [u.me]);
  await h.as(u.me);
  await h.one(`select my_matches(true) r`);
  await h.admin();
  h.eq('refresh after 5 minutes: recomputed', (await h.one(`select computed_at > now() - interval '1 minute' ok from match_cache where user_id = $1`, [u.me])).ok, true);
  await h.q(`update match_cache set computed_at = now() - interval '6 minutes' where user_id = $1`, [u.me]);
  await h.as(u.me);
  await h.one(`select my_matches() r`);
  await h.admin();
  h.eq('a normal open still uses the 6 hour cache', (await h.one(`select computed_at < now() - interval '1 minute' ok from match_cache where user_id = $1`, [u.me])).ok, true);

  // The plan, for the migration comment.
  if (process.env.MATCH_EXPLAIN) {
    const rows = await h.q(`explain (costs off) select match_compute($1)`, [u.me]);
    console.log(rows.map((r) => r['QUERY PLAN']).join('\n'));
  }
}
