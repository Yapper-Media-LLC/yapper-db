// 595: forums v2 (edit, delete, close/lock/pin, move, follow, settings, list_forum_posts). Same start as stage593
// (its stand-ins and live bodies), then 593, then 595 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS, LIVE, LIVE2 } from './stage593.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(LIVE2);
  await h.db.exec(mig('593_forums.sql'));

  // An old-style closed post before 595: it becomes closed + locked.
  const u = {};
  for (const n of ['owner', 'mem', 'mod', 'out', 'other']) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Hub', $1) returning id`, [u.owner])).id;
  for (const n of ['owner', 'mem', 'mod', 'other']) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u[n]]);
  await h.q(`insert into test_perms values ($1, $2, 'manage_messages')`, [sid, u.mod]);
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'forums'`, [sid]);
  await h.as(u.owner);
  const F = (await h.one(`select create_channel($1, 'help', 'forum') id`, [sid])).id;
  const G = (await h.one(`select create_channel($1, 'ideas', 'forum') id`, [sid])).id;
  await h.as(u.mem);
  const old = (await h.one(`select create_thread($1, 'old one', '{}', null, 'hi') id`, [F])).id;
  const old2 = (await h.one(`select create_thread($1, 'old two', '{}', null, 'hi') id`, [F])).id;
  await h.q(`select close_thread($1, true)`, [old2]);
  await h.as(u.mod);
  await h.q(`select close_thread($1, true)`, [old]);

  await h.admin();
  const MIG = mig('595_forums_v2.sql');
  await h.ok('595 runs', () => h.db.exec(MIG));
  await h.ok('595 re-runs cleanly', () => h.db.exec(MIG));
  await h.admin();
  h.eq('can_post_channel patched once', (await h.one(`select pg_get_functiondef('public.can_post_channel(uuid)'::regprocedure) d`)).d.split('forums_v2:').length - 1, 1);
  h.eq('old mod-closed post is now locked', (await h.one(`select locked from channels where id = $1`, [old])).locked, true);
  h.eq('old owner-closed post is only closed', (await h.one(`select locked, closed_at is not null c from channels where id = $1`, [old2])), { locked: false, c: true });

  // ---------- without forums_v2 nothing changes ----------
  await h.as(u.mem);
  h.eq('locked: members still can\'t post', (await h.one(`select can_post_channel($1) ok`, [old])).ok, false);
  await h.fails('v2 functions need the flag', `select edit_thread($1, 'new title')`, [old]);
  await h.fails('flag off: the author still can\'t reopen a mod close', `select close_thread($1, false)`, [old]);
  await h.as(u.mod);
  await h.q(`select close_thread($1, false)`, [old]);
  await h.admin();
  h.eq('old reopen unlocks too', (await h.one(`select locked, closed_at from channels where id = $1`, [old])), { locked: false, closed_at: null });
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'a reply')`, [old, u.other]);
  await h.as(u.mem);
  await h.fails('flag off: the author can\'t delete once others replied', `select delete_thread($1)`, [old]);

  await h.admin();
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'forums_v2'`, [sid]);

  // ---------- settings and tags ----------
  await h.as(u.owner);
  const tags = (await h.one(`select set_forum_tags($1, $2::jsonb) t`, [F, JSON.stringify([{ name: 'Bug', emoji: '🐛' }, { name: 'Solved', mod_only: true }, { name: 'Idea', mod_only: 'yes' }, 'junk'])])).t;
  h.eq('tags keep emoji and mod-only', tags.map((t) => [t.name, t.emoji ?? null, t.mod_only ?? false]), [['Bug', '🐛', false], ['Solved', null, true], ['Idea', null, false]]);
  const [bug, solved, idea] = tags.map((t) => t.id);
  await h.as(u.owner);
  await h.q(`select set_forum_tags($1, $2::jsonb)`, [G, JSON.stringify([{ name: 'bug' }, { name: 'Other' }])]);
  await h.q(`select set_forum_settings($1, $2, true, 'new', 'gallery')`, [F, '  Be nice and search first.  ']);
  await h.admin();
  h.eq('settings saved', await h.one(`select guidelines, require_tag, default_sort, default_layout from channels where id = $1`, [F]),
    { guidelines: 'Be nice and search first.', require_tag: true, default_sort: 'new', default_layout: 'gallery' });
  await h.as(u.mem);
  await h.fails('members can\'t change settings', `select set_forum_settings($1, 'x', false, null, null)`, [F]);
  await h.fails('settings can\'t be set directly', `update channels set guidelines = 'x' where id = $1`, [F]);
  await h.fails('a required tag', `select create_thread($1, 'no tags', '{}', null, 'hi')`, [F]);
  await h.fails('mod-only tags don\'t count for members', `select create_thread($1, 'only mod tag', $2, null, 'hi')`, [F, [solved]]);
  const post = (await h.one(`select create_thread($1, 'crash', $2, null, 'it crashes on start') id`, [F, [bug, solved]])).id;
  await h.admin();
  h.eq('member can\'t put a mod-only tag on', (await h.one(`select tags from channels where id = $1`, [post])).tags, [bug]);
  h.eq('the author follows their post', (await h.one(`select count(*)::int n from thread_follows where user_id = $1 and thread_id = $2`, [u.mem, post])).n, 1);

  // ---------- edit ----------
  await h.as(u.mem);
  await h.q(`select edit_thread($1, '  crash   on start ', null)`, [post]);
  await h.admin();
  h.eq('title edited, tags kept', await h.one(`select name, tags from channels where id = $1`, [post]), { name: 'crash on start', tags: [bug] });
  await h.as(u.mod);
  await h.q(`select edit_thread($1, null, $2)`, [post, [bug, solved]]);
  await h.as(u.mem);
  await h.q(`select edit_thread($1, null, $2)`, [post, [idea]]);
  await h.admin();
  h.eq('author retags, the mod-only tag stays', (await h.one(`select tags from channels where id = $1`, [post])).tags.sort(), [idea, solved].sort());
  await h.as(u.mem);
  await h.fails('empty title refused', `select edit_thread($1, '   ')`, [post]);
  await h.as(u.other);
  await h.fails('others can\'t edit', `select edit_thread($1, 'mine now')`, [post]);
  await h.as(u.out);
  await h.fails('outsiders can\'t edit', `select edit_thread($1, 'mine now')`, [post]);

  // ---------- close, lock, pin ----------
  await h.as(u.mem);
  await h.q(`select set_thread_state($1, 'close', true)`, [post]);
  await h.as(u.other);
  h.eq('closed: others can still reply', (await h.one(`select can_post_channel($1) ok`, [post])).ok, true);
  await h.admin();
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'same here')`, [post, u.other]);
  h.eq('a reply reopens it', (await h.one(`select closed_at from channels where id = $1`, [post])).closed_at, null);
  await h.as(u.mem);
  await h.fails('members can\'t lock', `select set_thread_state($1, 'lock', true)`, [post]);
  await h.fails('members can\'t pin', `select set_thread_state($1, 'pin', true)`, [post]);
  await h.as(u.mod);
  await h.q(`select set_thread_state($1, 'lock', true)`, [post]);
  await h.q(`select set_thread_state($1, 'close', true)`, [post]);
  await h.as(u.other);
  h.eq('locked: members can\'t reply', (await h.one(`select can_post_channel($1) ok`, [post])).ok, false);
  await h.as(u.mod);
  h.eq('locked: mods can', (await h.one(`select can_post_channel($1) ok`, [post])).ok, true);
  await h.admin();
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'mod note')`, [post, u.mod]);
  h.eq('a reply doesn\'t reopen a locked post', (await h.one(`select closed_at is not null c from channels where id = $1`, [post])).c, true);
  await h.as(u.mem);
  await h.fails('the author can\'t reopen a locked post', `select set_thread_state($1, 'close', false)`, [post]);
  await h.fails('...nor through the old close', `select close_thread($1, false)`, [post]);
  await h.q(`select set_thread_tags($1, $2)`, [post, [idea]]);
  await h.admin();
  h.eq('old retag keeps the mod-only tag', (await h.one(`select $2 = any(tags) ok from channels where id = $1`, [post, solved])).ok, true);
  await h.as(u.mem);
  await h.as(u.mod);
  await h.q(`select set_thread_state($1, 'lock', false)`, [post]);
  await h.q(`select set_thread_state($1, 'pin', true)`, [post]);
  await h.fails('unknown state', `select set_thread_state($1, 'explode', true)`, [post]);

  // ---------- listing ----------
  await h.as(u.other);
  const p2 = (await h.one(`select create_thread($1, 'feature request', $2, null, 'dark mode please') id`, [F, [idea]])).id;
  const p3 = (await h.one(`select create_thread($1, 'another bug', $2, null, 'the button is broken') id`, [F, [bug]])).id;
  let l = (await h.one(`select list_forum_posts($1, 'new') l`, [F])).l;
  h.eq('pinned first, then newest', l.map((t) => t.id).slice(0, 3), [post, p3, p2]);
  h.eq('pinned and followed flags', [l[0].pinned, l[0].followed, l[1].followed], [true, false, true]);
  h.eq('second page skips pins', (await h.one(`select list_forum_posts($1, 'new', null, null, false, $2, $3) l`, [F, l[1].created_at || null, p3])).l.some((t) => t.id === post), false);
  h.eq('multi-tag filter', (await h.one(`select list_forum_posts($1, 'new', $2) l`, [F, [idea]])).l.map((t) => t.id).sort(), [post, p2].sort());
  h.eq('search in titles', (await h.one(`select list_forum_posts($1, 'new', null, 'FEATURE') l`, [F])).l.map((t) => t.id), [p2]);
  h.eq('search in the first message', (await h.one(`select list_forum_posts($1, 'new', null, 'DARK mode') l`, [F])).l.map((t) => t.id), [p2]);
  h.eq('one letter doesn\'t filter', (await h.one(`select jsonb_array_length(list_forum_posts($1, 'new', null, 'z')) n`, [F])).n >= 3, true);
  h.eq('search escapes wildcards', (await h.one(`select list_forum_posts($1, 'new', null, '%_') l`, [F])).l, []);
  await h.q(`select follow_thread($1, false)`, [p3]);
  await h.q(`select follow_thread($1, true)`, [post]);
  h.eq('following filter', (await h.one(`select list_forum_posts($1, 'new', null, null, true) l`, [F])).l.map((t) => t.id).sort(), [post, p2].sort());
  await h.as(u.mem);
  await h.fails('follows can\'t be written directly', `insert into thread_follows (user_id, thread_id) values ($1, $2)`, [u.mem, p2]);
  h.eq('only your own follows are visible', (await h.one(`select count(*)::int n from thread_follows`)).n, 1);
  await h.as(u.out);
  h.eq('outsiders list nothing', (await h.one(`select list_forum_posts($1) l`, [F])).l, []);
  await h.fails('outsiders can\'t follow', `select follow_thread($1, true)`, [p2]);

  // ---------- post slowmode ----------
  await h.admin();
  await h.q(`update channels set slowmode = 60 where id = $1`, [F]);
  await h.as(u.other);
  await h.fails('slowmode spaces out posts', `select create_thread($1, 'again', $2, null, 'hi')`, [F, [bug]]);
  await h.as(u.mod);
  await h.q(`select create_thread($1, 'mod post', $2, null, 'hi')`, [F, [bug]]);
  await h.q(`select create_thread($1, 'mod post 2', $2, null, 'hi')`, [F, [bug]]);

  // ---------- move ----------
  await h.as(u.mem);
  await h.fails('members can\'t move', `select move_thread($1, $2)`, [post, G]);
  await h.as(u.mod);
  await h.fails('only to a forum', `select move_thread($1, $2)`, [post, old]);
  await h.q(`select edit_thread($1, null, $2)`, [post, [bug, idea]]);
  await h.q(`select move_thread($1, $2)`, [post, G]);
  await h.admin();
  const moved = await h.one(`select parent_id, tags, pinned_at, slowmode from channels where id = $1`, [post]);
  const gBug = (await h.one(`select forum_tags->0->>'id' id from channels where id = $1`, [G])).id;
  h.eq('moved, tags by name, unpinned, new slowmode', moved, { parent_id: G, tags: [gBug], pinned_at: null, slowmode: 0 });

  // ---------- delete ----------
  await h.as(u.other);
  await h.fails('others can\'t delete', `select delete_thread($1)`, [post]);
  await h.as(u.mem);
  await h.q(`select delete_thread($1)`, [post]);
  await h.admin();
  h.eq('the author deleted it, replies and follows too', await h.one(`select (select count(*)::int from channels where id = $1) c, (select count(*)::int from messages where channel_id = $1) m, (select count(*)::int from thread_follows where thread_id = $1) f`, [post]),
    { c: 0, m: 0, f: 0 });
}
