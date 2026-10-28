// 249: server watch ignores negated mentions ("no nsfw", "porn is not allowed") but still catches the real thing.
// Runs all of stage215 first (same fixtures), then 249.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import run215 from './stage215.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await run215(h);
  await h.admin();
  // A normal user: staff members' own servers are never scored.
  const owner = (await h.one(`select id from profiles p where not public.is_staff_user(p.id) order by created_at limit 1`)).id;
  const srv = async (name, description = null) => (await h.one(
    `insert into servers (name, owner_id, description, discoverable, member_count) values ($1, $2, $3, true, 3) returning id`, [name, owner, description])).id;
  const chan = async (sid, name) => (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', $1, $2, $3) returning id`, [name, sid, owner])).id;
  const say = (cid, content) => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, owner, content]);
  const row = async (sid) => (await h.q(`select score from server_watch where server_id = $1`, [sid]))[0]?.score ?? 0;

  // Hits the old scan makes on a rules message, which 249 should clear.
  const M = await srv('Old rules');
  await say(await chan(M, 'rules'), 'Rules: 1. no NSFW 2. do not post porn or gore 3. no nudes');
  await h.q(`select server_watch_scan()`);
  h.eq('old scan: rules message counted', (await h.one(`select count(*)::int n from server_watch_hits where server_id = $1`, [M])).n > 0, true);

  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '249_server_watch_negation.sql'), 'utf8');
  await h.db.exec(sql);
  await h.ok('migration runs twice', () => h.db.exec(sql));
  h.eq('stale negated hits cleared', (await h.one(`select count(*)::int n from server_watch_hits where server_id = $1`, [M])).n, 0);
  h.eq('next run is a full pass', (await h.one(`select terms_changed t from server_watch_state`)).t, true);

  const K = await srv('Chill rules place', 'Friendly server. No NSFW, no porn, no 18+ stuff');
  const kRules = await chan(K, 'rules');
  await say(kRules, '1. No NSFW\n2. No gore, porn or slurs\n3. 18+ content is not allowed\n4. Banned: hentai, nudes, r34');
  await say(kRules, 'non-18+ server, dont send nudes');
  const L = await srv('Spicy', 'nsfw allowed, 18+ only');
  await say(await chan(L, 'general'), 'free porn and hentai every day, no limits porn');

  const un = async (x) => (await h.one(`select server_watch_unneg($1) u`, [x])).u;
  await h.q(`select server_watch_scan()`);
  h.eq('rules-only server not flagged', await row(K) < 10, true);
  h.eq('old rules server not flagged', await row(M) < 10, true);
  h.eq('real NSFW server still flagged', await row(L) >= 10, true);
  h.eq('R34 club from 215 still flagged', (await h.one(`select score from server_watch s join servers v on v.id = s.server_id where v.name = 'R34 club'`)).score >= 10, true);

  h.eq('"not just nsfw" still counts', /nsfw/.test(await un('not just nsfw, we have memes')), true);
  h.eq('"18+ only, no minors" keeps 18+', /18\+/.test(await un('18+ only, no minors')), true);
  h.eq('rules post with "no extreme nsfw" ignored', /nsfw|gore/.test(await un('server rules: no spam. no racism. no extreme nsfw or gore. dont be rude')), false);
  h.eq('a rules line does not hide the rest', /nudes/.test(await un('rules: no minors, no spam, no doxxing. post your nudes and porn in #pics')), true);
  h.eq('rules note in an nsfw description keeps it', /hentai/.test(await un('hentai and porn drops daily!! (rules: no minors no spam dont leak)')), true);
  h.eq('helper not callable by users', (await h.one(`select has_function_privilege('authenticated', 'public.server_watch_unneg(text)', 'execute') e`)).e, false);
  h.eq('rules post that allows nsfw still counts', /18\+/.test(await un('rules: 18+ only. no minors. no spam. nsfw allowed in #nsfw. dont dox')), true);
  h.eq('"no limits porn" keeps porn', /porn/.test(await un('no limits porn server')), true);
}
