// 457: AniList, Last.fm and Trakt on profiles. Only the server writes links and interests; signed-in users read
// links unless hidden, change only their own prefs, delete only their own; one AniList/Trakt account per Yapin'
// account (Last.fm can repeat); interests are server only and go with the link; refresh turns are per source.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  const MIG = mig('457_media_connections.sql');
  await h.ok('457 runs', () => h.db.exec(MIG));
  await h.ok('457 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag media_connections in test', (await h.one(`select mode from feature_flags where key = 'media_connections'`)).mode, 'test');

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');

  // Users can't write links themselves (the server checks with the site first).
  await h.as(a);
  await h.fails('no insert as a user', `insert into media_links (user_id, source, account_id) values ($1, 'anilist', '1')`, [a]);
  await h.fails('no interests insert as a user', `insert into media_interests (user_id, source, kind, item_id, weight) values ($1, 'anilist', 'anime', '1', 1)`, [a]);
  await h.admin();

  await h.db.exec(`set role service_role`);
  await h.q(`insert into media_links (user_id, source, account_id, account_name) values ($1, 'anilist', '111', 'Alice'), ($1, 'lastfm', 'rj', 'RJ'), ($1, 'trakt', 'abc123', 'alice')`, [a]);
  await h.ok('same Last.fm name on two accounts', () => h.q(`insert into media_links (user_id, source, account_id, account_name) values ($1, 'lastfm', 'rj', 'RJ')`, [b]));
  await h.fails('one AniList account per Yapin account', `insert into media_links (user_id, source, account_id) values ($1, 'anilist', '111')`, [b]);
  await h.fails('one Trakt account per Yapin account', `insert into media_links (user_id, source, account_id) values ($1, 'trakt', 'abc123')`, [b]);
  await h.fails('unknown source refused', `insert into media_links (user_id, source, account_id) values ($1, 'spotify', 'x')`, [b]);
  await h.fails('bad account id refused', `update media_links set account_id = 'a b/c' where user_id = $1 and source = 'lastfm'`, [a]);
  await h.fails('profile link must match the source', `update media_links set profile_url = 'https://trakt.tv/users/x' where user_id = $1 and source = 'anilist'`, [a]);
  await h.ok('right profile link ok', () => h.q(`update media_links set profile_url = 'https://anilist.co/user/111' where user_id = $1 and source = 'anilist'`, [a]));
  await h.fails('non-https avatar refused', `update media_links set avatar_url = 'http://x/y.png' where user_id = $1 and source = 'anilist'`, [a]);
  await h.fails('huge data refused', `update media_links set data = jsonb_build_object('x', repeat('y', 40000)) where user_id = $1 and source = 'anilist'`, [a]);

  // Saving a refresh: card fields + interests together, only for the account still linked.
  const items = JSON.stringify([
    { kind: 'anime', item_id: '20', title: 'NARUTO', weight: 1 },
    { kind: 'anime', item_id: '1735', title: 'Shippuden', weight: 5 },
  ]);
  h.eq('save refresh', (await h.one(`select media_save_refresh($1, 'anilist', '111', '{"account_name":"Alice2","data":{"top":[1]}}', $2) ok`, [a, items])).ok, true);
  h.eq('interests written', (await h.one(`select count(*)::int n from media_interests where user_id = $1`, [a])).n, 2);
  h.eq('weight clamped to 1', (await h.one(`select weight from media_interests where user_id = $1 and item_id = '1735'`, [a])).weight, 1);
  h.eq('refreshed_at set', (await h.one(`select refreshed_at is not null ok from media_links where user_id = $1 and source = 'anilist'`, [a])).ok, true);
  h.eq('next background refresh a day out', (await h.one(`select next_refresh_at > now() + interval '23 hours' ok from media_links where user_id = $1 and source = 'anilist'`, [a])).ok, true);
  h.eq('new links are due at once', (await h.one(`select next_refresh_at <= now() ok from media_links where user_id = $1 and source = 'trakt'`, [a])).ok, true);
  h.eq('other account: not saved', (await h.one(`select media_save_refresh($1, 'anilist', '999', '{}', '[]') ok`, [a])).ok, false);
  h.eq('private refresh keeps interests', (await h.one(`select media_save_refresh($1, 'anilist', '111', '{"is_public":false}', '[]') ok`, [a])).ok, true);
  h.eq('interests still there', (await h.one(`select count(*)::int n from media_interests where user_id = $1`, [a])).n, 2);
  await h.fails('too many items refused', `select media_save_refresh($1, 'anilist', '111', '{}', (select jsonb_agg(jsonb_build_object('kind','anime','item_id',i::text,'weight',1)) from generate_series(1, 151) i))`, [a]);
  await h.fails('bad kind refused', `select media_save_refresh($1, 'anilist', '111', '{}', '[{"kind":"porn","item_id":"1","weight":1}]')`, [a]);
  await h.db.exec(`reset role`);

  await h.as(b);
  h.eq('others can read a link', (await h.one(`select account_name from media_links where user_id = $1 and source = 'anilist'`, [a])).account_name, 'Alice2');
  await h.fails('others cannot read interests', `select * from media_interests`);
  await h.fails('users cannot call save', `select media_save_refresh($1, 'lastfm', 'rj', '{}', '[]')`, [b]);
  await h.fails('users cannot claim refresh turns', `select media_claim_refresh($1, 'lastfm', 60)`, [b]);
  await h.fails('no data update as a user', `update media_links set data = '{}' where user_id = $1`, [b]);
  await h.q(`update media_links set prefs = '{"hidden":true}' where user_id = $1 and source = 'anilist'`, [a]);
  await h.q(`delete from media_links where user_id = $1`, [a]);
  await h.admin();
  h.eq('changing or deleting someone else’s link does nothing',
    (await h.one(`select count(*)::int n from media_links where user_id = $1 and prefs = '{}'`, [a])).n, 3);

  // Hidden: only the owner reads it.
  await h.as(a);
  await h.fails('prefs keep their shape', `update media_links set prefs = '{"hidden":"yes"}' where user_id = $1 and source = 'anilist'`, [a]);
  await h.q(`update media_links set prefs = '{"hidden":true}' where user_id = $1 and source = 'anilist'`, [a]);
  h.eq('owner still sees a hidden link', (await h.one(`select count(*)::int n from media_links where user_id = $1`, [a])).n, 3);
  await h.as(b);
  h.eq('others don’t see a hidden link', (await h.one(`select count(*)::int n from media_links where user_id = $1`, [a])).n, 2);

  // Disconnect takes the interests with it.
  await h.as(a);
  await h.q(`delete from media_links where user_id = $1 and source = 'anilist'`, [a]);
  await h.admin();
  h.eq('own disconnect works', (await h.one(`select count(*)::int n from media_links where user_id = $1 and source = 'anilist'`, [a])).n, 0);
  h.eq('interests deleted with it', (await h.one(`select count(*)::int n from media_interests where user_id = $1`, [a])).n, 0);

  // Refresh turns: once per gap per source, and a disconnect doesn't reset it.
  await h.db.exec(`set role service_role`);
  h.eq('first claim', (await h.one(`select media_claim_refresh($1, 'trakt', 3600) ok`, [a])).ok, true);
  h.eq('second claim within the gap refused', (await h.one(`select media_claim_refresh($1, 'trakt', 3600) ok`, [a])).ok, false);
  h.eq('other source has its own turn', (await h.one(`select media_claim_refresh($1, 'lastfm', 3600) ok`, [a])).ok, true);
  await h.q(`update media_refresh_log set at = now() - interval '2 hours' where user_id = $1 and source = 'trakt'`, [a]);
  h.eq('claim again after the gap', (await h.one(`select media_claim_refresh($1, 'trakt', 3600) ok`, [a])).ok, true);
  await h.db.exec(`reset role`);

  await h.q(`set role anon`);
  await h.fails('anon cannot read', `select * from media_links`);
  await h.db.exec(`reset role`);
}
