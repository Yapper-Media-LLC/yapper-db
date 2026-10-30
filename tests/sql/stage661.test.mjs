// 661: lobby feeds and more leaderboards (flag lobby_feeds). Feeds: managers only, tokens stored hashed, rotate kills
// the old URL, the service-role post checks token, flag and filters, keeps the last 20, rate limit per feed. Boards:
// messages (last 7 days, rolled up into lobby_msg_days, cached) and invites, current members only, members only.
// The lobby save keeps the feed section and the leaderboard's kinds. Stand-ins for the later helpers it leans on.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '661_lobby_feeds.sql'), 'utf8');

const STANDINS = String.raw`
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.invites add column if not exists vanity boolean not null default false;
alter table public.messages add column if not exists webhook jsonb;
alter table public.messages add column if not exists system text;
alter table public.channels add column if not exists ticket_by uuid;
alter table public.channels add column if not exists private boolean not null default false;
create or replace function public.server_watch_public_channel(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select not c.private and c.ticket_by is null from public.channels c where c.id = cid), false) $$;
create table if not exists public.site_bans (user_id uuid primary key);
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.bot_accounts (user_id uuid primary key);
create table if not exists public.t661_audit (sid uuid, act text, extra jsonb);
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())); $$;
create or replace function public.is_staff() returns boolean language sql as $$ select false $$;
create or replace function public.bad_name(t text) returns boolean language sql as $$ select t ilike '%badword%' $$;
create or replace function public.has_adult_link(t text) returns boolean language sql as $$ select t ilike '%adult.example%' $$;
create or replace function public.lobby_text_problem(t text) returns text language sql as $$
  select case when t ilike '%adult.example%' then 'Links to that site aren''t allowed on Yapper.' when t ilike '%slurword%' then 'Some of that text isn''t allowed' end $$;
create or replace function public.has_self_harm_incitement(t text) returns boolean language sql as $$ select false $$;
create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb) returns void
  language sql security definer set search_path = public as $$ insert into public.t661_audit values (sid, act, extra) $$;
create table if not exists public.webhook_rate (k text, bucket bigint, n int not null default 0, at timestamptz not null default now(),
  constraint webhook_rate_pkey primary key (k, bucket));
create or replace function public.webhook_hit(k text, win int, lim int) returns numeric
language plpgsql security definer set search_path = public as $$
declare e numeric := extract(epoch from clock_timestamp()); b bigint := floor(e / win); got int;
begin
  insert into public.webhook_rate as r (k, bucket, n) values (k, b, 1)
    on conflict on constraint webhook_rate_pkey do update set n = r.n + 1 where r.n < lim
    returning r.n into got;
  if got is null then return greatest(0.001, round((b + 1) * win - e, 3)); end if;
  return 0;
end $$;
create table if not exists public.server_lobby (server_id uuid primary key references public.servers(id) on delete cascade,
  about text not null default '', faq jsonb not null default '[]', featured uuid[] not null default '{}', show_staff boolean not null default true,
  style jsonb not null default '{}', sections jsonb not null default '[]');
create or replace function public.set_server_lobby(sid uuid, p_about text, p_faq jsonb, p_featured uuid[], p_show_staff boolean) returns void
  language sql security definer set search_path = public as $$
  insert into public.server_lobby (server_id, about) values (sid, coalesce(p_about, '')) on conflict (server_id) do update set about = excluded.about $$;
insert into public.feature_flags (key, label, description, mode) values ('lobby_v2', 'Lobby v2', '', 'everyone') on conflict (key) do update set mode = 'everyone';
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`661 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('661 runs', () => h.db.exec(MIG));
  await h.ok('661 re-runs cleanly', () => h.db.exec(MIG));
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'lobby_feeds'`);
  h.eq('flag is test mode', flag.mode, 'test');
  h.eq('flag test server', flag.servers, ['00000000-0000-4000-8000-00000000b001']);
  h.eq('flag test user', flag.users, ['00000000-0000-4000-8000-00000000a001']);
  for (const t of ['lobby_feeds', 'lobby_feed_posts', 'lobby_msg_days', 'lobby_board_cache']) {
    h.eq(`RLS on ${t}`, (await h.one(`select relrowsecurity from pg_class where oid = $1::regclass`, [`public.${t}`])).relrowsecurity, true);
  }

  const owner = await h.signup('owner661@x.test', 'owner661');
  const mem = await h.signup('mem661@x.test', 'mem661');
  const mem2 = await h.signup('mem2_661@x.test', 'mem2_661');
  const gone = await h.signup('gone661@x.test', 'gone661');
  const banned = await h.signup('ban661@x.test', 'ban661');
  const out = await h.signup('out661@x.test', 'out661');
  const SID = '00000000-0000-4000-8000-00000000b001';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Test', $2)`, [SID, owner]);
  const OFF = (await h.one(`insert into servers (name, owner_id) values ('Off', $1) returning id`, [owner])).id;
  await h.q(`insert into server_members (server_id, user_id) select $1, unnest($2::uuid[]) on conflict do nothing`, [SID, [owner, mem, mem2, banned]]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [OFF, owner]);
  await h.q(`insert into site_bans (user_id) values ($1)`, [banned]);

  // ---------- Feeds: managing ----------
  await h.as(mem);
  await h.fails('a member cannot make a feed', `select lobby_feed_create($1, 'News')`, [SID]);
  await h.fails('a member cannot list feeds', `select * from lobby_feed_list($1)`, [SID]);
  await h.fails('members cannot read the feeds table', `select * from lobby_feeds`);
  await h.fails('members cannot read the posts table', `select * from lobby_feed_posts`);
  await h.as(owner);
  await h.fails('no feeds where the flag is off', `select lobby_feed_create($1, 'News')`, [OFF]);
  await h.fails('bad names are refused', `select lobby_feed_create($1, 'badword here')`, [SID]);
  await h.fails('empty names are refused', `select lobby_feed_create($1, '   ')`, [SID]);
  const made = (await h.one(`select lobby_feed_create($1, '  YouTube   uploads ') j`, [SID])).j;
  const fid = made.id;
  let tok = made.token;
  h.eq('token is 64 hex', /^[0-9a-f]{64}$/.test(tok), true);
  const list = await h.q(`select * from lobby_feed_list($1)`, [SID]);
  h.eq('list shows the feed with a tidy name', list.map((x) => x.name), ['YouTube uploads']);
  h.eq('list has no token column', Object.keys(list[0]).includes('token_hash'), false);
  await h.admin();
  h.eq('only the hash is stored', (await h.one(`select token_hash = encode(sha256(convert_to($2, 'UTF8')), 'hex') ok from lobby_feeds where id = $1`, [fid, tok])).ok, true);
  h.eq('create is audited', (await h.one(`select count(*)::int n from t661_audit where extra ->> 'feed' = 'create'`)).n, 1);
  await h.as(owner);
  for (let i = 0; i < 4; i++) await h.q(`select lobby_feed_create($1, $2)`, [SID, `Feed ${i}`]);
  await h.fails('up to 5 feeds', `select lobby_feed_create($1, 'Six')`, [SID]);
  await h.as(mem);
  await h.fails('a member cannot rotate', `select lobby_feed_rotate($1)`, [fid]);
  await h.fails('a member cannot remove', `select lobby_feed_remove($1)`, [fid]);
  await h.fails('a member cannot post through the service function', `select lobby_feed_post($1, $2, 't', 'x', null, null)`, [fid, tok]);
  await h.fails('a member cannot take the rate limit', `select lobby_feed_take($1, $2)`, [fid, tok]);

  // ---------- Feeds: posting (service role = admin here) ----------
  let codes;
  await h.admin();
  h.eq('wrong token', (await h.one(`select lobby_feed_take($1, $2) j`, [fid, '0'.repeat(64)])).j.code, 401);
  // A second feed for the junk-token limit, so the main feed's counters stay clean.
  const other = (await h.one(`select id from lobby_feeds where name = 'Feed 0'`)).id;
  codes = [];
  for (let i = 0; i < 31; i++) codes.push((await h.one(`select lobby_feed_take($1, $2) j`, [other, 'f'.repeat(64)])).j.code);
  h.eq('junk tokens get limited after 30 a minute', [codes[29], codes[30]], [401, 429]);
  h.eq('unknown feed', (await h.one(`select lobby_feed_take(gen_random_uuid(), $1) j`, [tok])).j.code, 404);
  h.eq('right token passes', (await h.one(`select lobby_feed_take($1, $2) j`, [fid, tok])).j.ok, true);
  await h.fails('post with a wrong token fails', `select lobby_feed_post($1, $2, 'Hi', null, null, null)`, [fid, '0'.repeat(64)]);
  await h.fails('empty post fails', `select lobby_feed_post($1, $2, '  ', '', null, null)`, [fid, tok]);
  await h.fails('http links fail', `select lobby_feed_post($1, $2, 'Hi', null, 'http://x.com', null)`, [fid, tok]);
  await h.fails('adult links fail', `select lobby_feed_post($1, $2, 'Hi', 'see https://adult.example/x', null, null)`, [fid, tok]);
  await h.fails('slurs fail', `select lobby_feed_post($1, $2, 'slurword', null, null, null)`, [fid, tok]);
  await h.fails('overlong text fails', `select lobby_feed_post($1, $2, 'Hi', $3, null, null)`, [fid, tok, 'x'.repeat(1001)]);
  await h.ok('a good post', () => h.q(`select lobby_feed_post($1, $2, 'New video', 'Go watch', 'https://youtu.be/abc', 'javascript:alert(1)')`, [fid, tok]));
  h.eq('a non-https image is dropped', (await h.one(`select image from lobby_feed_posts where feed_id = $1`, [fid])).image, null);
  for (let i = 0; i < 24; i++) await h.q(`select lobby_feed_post($1, $2, $3, null, null, 'https://i.ytimg.com/a.jpg')`, [fid, tok, `Post ${i}`]);
  h.eq('a feed keeps its last 20', (await h.one(`select count(*)::int n from lobby_feed_posts where feed_id = $1`, [fid])).n, 20);
  h.eq('post counter', Number((await h.one(`select posts from lobby_feeds where id = $1`, [fid])).posts), 25);
  // Rate limit: 5 a minute per feed (one taken above).
  codes = [];
  for (let i = 0; i < 5; i++) codes.push((await h.one(`select lobby_feed_take($1, $2) j`, [fid, tok])).j.code ?? 'ok');
  h.eq('the 6th take in a minute is limited', codes, ['ok', 'ok', 'ok', 'ok', 429]);

  // Rotate: the old token stops working.
  await h.as(owner);
  const tok2 = (await h.one(`select lobby_feed_rotate($1) t`, [fid])).t;
  await h.admin();
  h.eq('old token is dead', (await h.one(`select lobby_feed_take($1, $2) j`, [fid, tok])).j.code, 401);
  await h.fails('old token cannot post', `select lobby_feed_post($1, $2, 'Hi', null, null, null)`, [fid, tok]);
  await h.ok('new token posts', () => h.q(`select lobby_feed_post($1, $2, 'Latest', null, null, null)`, [fid, tok2]));
  tok = tok2;

  // Reading: members see the last 10, newest first; outsiders and banned accounts nothing.
  await h.as(mem);
  const posts = (await h.one(`select lobby_feed_posts($1) j`, [SID])).j;
  h.eq('10 posts', posts.length, 10);
  h.eq('newest first', posts[0].title, 'Latest');
  h.eq('feed name on posts', posts[0].feed, 'YouTube uploads');
  await h.as(out);
  h.eq('outsiders get nothing', (await h.one(`select lobby_feed_posts($1) j`, [SID])).j, null);
  await h.as(banned);
  h.eq('banned accounts get nothing', (await h.one(`select lobby_feed_posts($1) j`, [SID])).j, null);

  // Flag off for the server: posting stops.
  await h.admin();
  await h.q(`update feature_flags set servers = '{}' where key = 'lobby_feeds'`);
  await h.fails('no posts while the flag is off', `select lobby_feed_post($1, $2, 'Hi', null, null, null)`, [fid, tok]);
  await h.q(`update feature_flags set servers = $1 where key = 'lobby_feeds'`, [[SID]]);

  // Remove: the feed and its posts go.
  await h.as(owner);
  await h.ok('owner removes the feed', () => h.q(`select lobby_feed_remove($1)`, [fid]));
  await h.admin();
  h.eq('posts went with it', (await h.one(`select count(*)::int n from lobby_feed_posts where feed_id = $1`, [fid])).n, 0);

  // ---------- Leaderboards ----------
  const rows = (b) => (b ?? []).map((r) => [r.user_id, r.n]);
  await h.admin();
  // Message rules from 001..024 (new-account slowmode and friends) aren't what this is about.
  await h.q(`alter table messages disable trigger user`);
  const ch = (await h.one(`insert into channels (name, server_id, kind) values ('general', $1, 'text') returning id`, [SID])).id;
  const add = (uid, n, ago = '1 hour') => h.q(`insert into messages (channel_id, author_id, content, created_at)
    select $1, $2, 'hi', now() - $4::interval from generate_series(1, $3)`, [ch, uid, n, ago]);
  await add(mem, 5);
  await add(mem2, 3);
  await add(owner, 9, '10 days'); // too old
  await add(banned, 20);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [SID, gone]);
  await add(gone, 7);
  await h.q(`insert into messages (channel_id, author_id, content, webhook) values ($1, $2, 'hook', '{}'::jsonb)`, [ch, owner]);
  const staff = (await h.one(`insert into channels (name, server_id, kind, private) values ('staff', $1, 'text', true) returning id`, [SID])).id;
  await h.q(`insert into messages (channel_id, author_id, content, created_at) select $1, $2, 'psst', now() - interval '1 hour' from generate_series(1, 50)`, [staff, owner]);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [SID, gone]);

  await h.as(out);
  h.eq('outsiders get no board', (await h.one(`select lobby_board($1, 'messages') j`, [SID])).j, null);
  await h.as(mem);
  h.eq('unknown kind', (await h.one(`select lobby_board($1, 'voice') j`, [SID])).j, null);
  // The first build goes a day at a time: a week of history takes 7 views, each saving its progress.
  let board = (await h.one(`select lobby_board($1, 'messages') j`, [SID])).j;
  h.eq('first view only covers the oldest day', rows(board), []);
  await h.admin();
  h.eq('progress saved, still stale', (await h.one(`select rolled_to < now() - interval '5 days' a, at < now() - interval '10 minutes' b from lobby_board_cache where server_id = $1`, [SID])), { a: true, b: true });
  await h.as(mem);
  for (let i = 0; i < 7; i++) board = (await h.one(`select lobby_board($1, 'messages') j`, [SID])).j;
  h.eq('messages board: members only, no banned, last 7 days, no webhooks, no private channels', rows(board), [[mem, 5], [mem2, 3]]);
  await h.admin();
  h.eq('caught up: fresh now', (await h.one(`select at > now() - interval '1 minute' f from lobby_board_cache where server_id = $1 and kind = 'messages'`, [SID])).f, true);
  // Asking again once it's stale, with nothing new, doesn't count anything twice.
  await h.q(`update lobby_board_cache set at = now() - interval '11 minutes' where server_id = $1`, [SID]);
  await h.as(mem);
  h.eq('no double counting on a rebuild', rows((await h.one(`select lobby_board($1, 'messages') j`, [SID])).j), [[mem, 5], [mem2, 3]]);
  await h.fails('members cannot read the cache table', `select * from lobby_board_cache`);
  // Cached: new messages don't show until the cache is 10 minutes old, then only the new ones are added.
  await h.admin();
  await add(mem2, 4, '1 second');
  await h.q(`update messages set created_at = now() - interval '1 minute' where created_at > now() - interval '5 seconds'`);
  await h.as(mem);
  board = (await h.one(`select lobby_board($1, 'messages') j`, [SID])).j;
  h.eq('cached answer', rows(board)[0], [mem, 5]);
  await h.admin();
  await h.q(`update lobby_board_cache set at = now() - interval '11 minutes', rolled_to = now() - interval '2 minutes' where server_id = $1`, [SID]);
  await h.as(mem);
  board = (await h.one(`select lobby_board($1, 'messages') j`, [SID])).j;
  h.eq('rebuilt with only the new messages added', rows(board), [[mem2, 7], [mem, 5]]);

  // Invites: uses by creator, no vanity.
  await h.admin();
  await h.q(`insert into invites (code, server_id, created_by, uses) values ('aaa661', $1, $2, 4), ('bbb661', $1, $2, 2), ('ccc661', $1, $3, 1), ('ddd661', $1, $3, 0), ('vvv661', $1, $4, 50)`, [SID, mem2, mem, owner]);
  await h.q(`update invites set vanity = true where code = 'vvv661'`);
  await h.as(mem);
  board = (await h.one(`select lobby_board($1, 'invites') j`, [SID])).j;
  h.eq('invites board', rows(board), [[mem2, 6], [mem, 1]]);

  // ---------- The lobby save ----------
  await h.as(owner);
  await h.ok('save with feed and kinds', () => h.q(`select set_server_lobby_v2($1, 'hi', '[]', '{}', true, '{}', $2)`,
    [SID, JSON.stringify([{ id: 'feed', on: true, side: 'x' }, { id: 'leaderboard', on: true, side: true, kinds: ['messages', 'levels', 'messages'] }])]));
  await h.admin();
  h.eq('sections saved (with 658 side flags kept, junk side dropped)', (await h.one(`select sections::text = $2::jsonb::text ok from server_lobby where server_id = $1`,
    [SID, JSON.stringify([{ id: 'feed', on: true }, { id: 'leaderboard', on: true, side: true, kinds: ['messages', 'levels'] }])])).ok, true);
  await h.as(owner);
  await h.fails('unknown board kind', `select set_server_lobby_v2($1, 'hi', '[]', '{}', true, '{}', $2)`,
    [SID, JSON.stringify([{ id: 'leaderboard', on: true, kinds: ['voice'] }])]);
  await h.fails('too many kinds', `select set_server_lobby_v2($1, 'hi', '[]', '{}', true, '{}', $2)`,
    [SID, JSON.stringify([{ id: 'leaderboard', on: true, kinds: ['levels', 'messages', 'invites', 'levels'] }])]);
  // Flag off: the feed block and the boards aren't kept.
  await h.admin();
  await h.q(`update feature_flags set servers = '{}' where key = 'lobby_feeds'`);
  await h.as(owner);
  await h.q(`select set_server_lobby_v2($1, 'hi', '[]', '{}', true, '{}', $2)`,
    [SID, JSON.stringify([{ id: 'feed', on: true }, { id: 'leaderboard', on: true, kinds: ['messages'] }])]);
  await h.admin();
  h.eq('flag off drops feed and kinds', (await h.one(`select sections::text = $2::jsonb::text ok from server_lobby where server_id = $1`,
    [SID, JSON.stringify([{ id: 'leaderboard', on: true }])])).ok, true);
  await h.q(`update feature_flags set servers = $1 where key = 'lobby_feeds'`, [[SID]]);
  await h.as(mem);
  await h.fails('members cannot save', `select set_server_lobby_v2($1, 'hi', '[]', '{}', true, '{}', '[]')`, [SID]);
}
