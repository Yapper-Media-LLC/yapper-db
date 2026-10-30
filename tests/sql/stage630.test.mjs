// 630/631: Wordy, the word game bot (internal keys say wordle). A game per person per UTC day, guesses only count in the picked channel while a game runs,
// scoring handles doubles, stats/streaks/board, the daily recap, and nobody can read the word list or games from
// the client. Starts from stage 24 with the feature flag migrations plus stand-ins for the live-only bot bits.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('630_wordle_bot.sql');
const RENAME = mig('633_wordy_rename.sql');
const WORDS = mig('631_wordle_words.sql');

const BOT = '00000000-0000-4000-8000-00000000a009';
const STANDINS = String.raw`
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists badges text[];
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists dms_from text;
alter table public.profiles add column if not exists bio text;
create table if not exists public.media_scans (bucket text, path text, verdict text, score int, scanned_at timestamptz, primary key (bucket, path));
create table if not exists public.bot_accounts (bot text primary key, user_id uuid);
create table if not exists public.server_bots (server_id uuid, bot text, enabled boolean default true, config jsonb default '{}', primary key (server_id, bot));
create or replace function public.bot_id(p_bot text) returns uuid language sql stable security definer set search_path = public
  as $$ select user_id from public.bot_accounts where bot = p_bot $$;
create or replace function public.bot_cfg(sid uuid, p_bot text) returns jsonb language sql stable security definer set search_path = public
  as $$ select config from public.server_bots where server_id = sid and bot = p_bot and enabled $$;
create or replace function public.log_name(uid uuid) returns text language sql stable security definer set search_path = public
  as $$ select coalesce((select coalesce(display_name, username) from public.profiles where id = uid), 'someone') $$;
create table if not exists public.bot_commands (bot_id uuid, name text, description text);
create table if not exists public.bots (id uuid primary key, name text);
create table if not exists public.bot_servers (bot_id uuid, server_id uuid);
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`630 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  // The bot account exists already (the live block writes auth.users columns PGlite's stub doesn't have).
  await h.q(`insert into auth.users (id, email, raw_user_meta_data) values ($1, 'wordle@yapper.website', '{"username":"Wordy"}')`, [BOT]);
  await h.q(`insert into public.bot_accounts (bot, user_id) values ('wordle', $1)`, [BOT]);
  await h.ok('630 runs', () => h.db.exec(MIG));
  await h.ok('631 runs', () => h.db.exec(WORDS));
  await h.ok('630 re-runs cleanly', () => h.db.exec(MIG));
  await h.ok('631 re-runs cleanly', () => h.db.exec(WORDS));
  await h.ok('633 runs', () => h.db.exec(RENAME));
  await h.ok('633 re-runs cleanly', () => h.db.exec(RENAME));
  h.eq('bot is called Wordy', (await h.one(`select username, display_name from profiles where id = $1`, [BOT])), { username: 'Wordy', display_name: 'Wordy' });
  h.eq('word list loaded', (await h.one(`select count(*)::int as n, (count(*) filter (where answer))::int as a from wordle_words`)), { n: 14840, a: 2315 });

  // Scoring.
  h.eq('all green', (await h.one(`select wordle_score('crane', 'crane') s`)).s, 'ggggg');
  h.eq('doubles: allee vs eagle', (await h.one(`select wordle_score('allee', 'eagle') s`)).s, 'yyxyg');
  h.eq('a letter is yellow only as often as it is left', (await h.one(`select wordle_score('eerie', 'other') s`)).s, 'yxyxx');
  h.eq('squares', (await h.one(`select wordle_squares('gyx') s`)).s, '🟩🟨⬛');
  h.eq('same word for the same day', (await h.one(`select wordle_answer(date '2026-11-01') = wordle_answer(date '2026-11-01') as ok`)).ok, true);
  h.eq('an answer is a listed answer', (await h.one(`select exists (select 1 from wordle_words where answer and word = wordle_answer(date '2026-11-01')) as ok`)).ok, true);
  h.eq('Wordy #1 is Oct 28', (await h.one(`select wordle_no(date '2026-10-28') n`)).n, 1);

  const owner = await h.signup('o@x.com', 'owner');
  const alice = await h.signup('a@x.com', 'alice');
  const bob = await h.signup('b@x.com', 'bob');
  const outsider = await h.signup('x@x.com', 'outsider');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days' where id in ($1, $2, $3, $4, $5)`, [owner, alice, bob, outsider, BOT]);
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  const S2 = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner])).id;
  for (const u of [owner, alice, bob]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S2, alice]);
  const chan = async (sid, name) => (await h.one(`insert into channels (server_id, name, kind) values ($1, $2, 'text') returning id`, [sid, name])).id;
  const wc = await chan(S, 'wordle');
  const general = await chan(S, 'general');
  const wc2 = await chan(S2, 'wordle');
  await h.q(`insert into server_bots (server_id, bot, enabled, config) values ($1, 'wordle', true, jsonb_build_object('channel_id', $2::text)), ($3, 'wordle', true, jsonb_build_object('channel_id', $4::text))`, [S, wc, S2, wc2]);

  const say = (who, cid, text) => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, who, text]);
  const botMsgs = async (cid) => h.q(`select content from messages where channel_id = $1 and author_id = $2 order by created_at, id`, [cid, BOT]);
  const answer = (await h.one(`select wordle_answer(wordle_day()) a`)).a;
  const wrong = answer === 'crane' ? 'slate' : 'crane';

  // Flag off: nothing happens.
  await say(alice, wc, '/wordy');
  h.eq('silent while the flag is off', (await botMsgs(wc)).length, 0);
  await h.q(`update feature_flags set servers = array[$1, $2]::uuid[] where key = 'wordle_bot'`, [S, S2]);

  // Wrong channel: nothing.
  await say(alice, general, '/wordy');
  await say(alice, general, wrong);
  h.eq('silent outside the picked channel', (await botMsgs(general)).length, 0);
  h.eq('no game started from the wrong channel', (await h.q(`select 1 from wordle_games where user_id = $1`, [alice])).length, 0);

  // A bare word with no game running is just chat.
  await say(alice, wc, wrong);
  h.eq('bare word without a game is ignored', (await botMsgs(wc)).length, 0);

  // Start, guess, win.
  await say(alice, wc, '/wordy');
  let m = await botMsgs(wc);
  h.eq('start replies once', m.length, 1);
  h.eq('start names the day', m[0].content.includes('Wordy #'), true);
  h.eq('game row', (await h.one(`select server_id, channel_id, guesses, won from wordle_games where user_id = $1 and day = wordle_day()`, [alice])), { server_id: S, channel_id: wc, guesses: [], won: false });
  await say(alice, wc, 'zzzzz');
  m = await botMsgs(wc);
  h.eq('unknown word is refused', m[m.length - 1].content.includes("isn't in the word list"), true);
  h.eq('unknown word is not a guess', (await h.one(`select guesses from wordle_games where user_id = $1 and day = wordle_day()`, [alice])).guesses, []);
  await say(alice, wc, wrong.toUpperCase());
  m = await botMsgs(wc);
  h.eq('a guess gets a board', /^[🟩🟨⬛]{5} \|\|[A-Z]{5}\|\|\n1\/6 used\.$/u.test(m[m.length - 1].content), true);
  h.eq('guess stored lower-case', (await h.one(`select guesses from wordle_games where user_id = $1 and day = wordle_day()`, [alice])).guesses, [wrong]);
  h.eq('the bot reply answers the guess', (await h.one(`select exists (select 1 from messages b join messages g on g.id = b.reply_to_id where b.author_id = $1 and g.author_id = $2 and g.content = $3) as ok`, [BOT, alice, wrong.toUpperCase()])).ok, true);
  await say(alice, wc, `/wordy ${answer}`);
  m = await botMsgs(wc);
  h.eq('win announced', m[m.length - 1].content.startsWith('🎉 Got it! Wordy #'), true);
  h.eq('win shows 2/6', m[m.length - 1].content.includes('**2/6**'), true);
  h.eq('game finished and won', (await h.one(`select won, finished_at is not null as done, array_length(guesses, 1) n from wordle_games where user_id = $1 and day = wordle_day()`, [alice])), { won: true, done: true, n: 2 });
  const before = (await botMsgs(wc)).length;
  await say(alice, wc, wrong);
  h.eq('bare word after finishing is ignored', (await botMsgs(wc)).length, before);
  await say(alice, wc, '/wordy');
  m = await botMsgs(wc);
  h.eq('/wordy after finishing shows the result', m[m.length - 1].content.includes('already finished'), true);
  h.eq('result board has no letters', /\|\|/.test(m[m.length - 1].content), false);

  // One game a day, wherever you play.
  await say(alice, wc2, '/wordy');
  m = await botMsgs(wc2);
  h.eq('second server says already played', m[m.length - 1].content.includes('another server'), true);
  h.eq('still one game row', (await h.q(`select 1 from wordle_games where user_id = $1`, [alice])).length, 1);

  // Bob loses in six.
  await say(bob, wc, `/wordy ${wrong}`);
  for (let i = 0; i < 5; i++) await say(bob, wc, wrong);
  h.eq('six tries end the game', (await h.one(`select won, finished_at is not null as done, array_length(guesses, 1) n from wordle_games where user_id = $1 and day = wordle_day()`, [bob])), { won: false, done: true, n: 6 });
  m = await botMsgs(wc);
  h.eq('loss reveals the word behind a spoiler', m[m.length - 1].content.includes(`||${answer.toUpperCase()}||`), true);
  const b2 = (await botMsgs(wc)).length;
  await say(bob, wc, wrong);
  h.eq('no seventh guess', (await botMsgs(wc)).length, b2);

  // Streaks and stats.
  await h.q(`insert into wordle_games (user_id, day, server_id, channel_id, guesses, won, finished_at) values
    ($1, wordle_day() - 1, $2, $3, '{"a","b","c"}', true, now()), ($1, wordle_day() - 2, $2, $3, '{"a","b","c","d"}', true, now()),
    ($1, wordle_day() - 4, $2, $3, '{"a"}', true, now()), ($1, wordle_day() - 5, $2, $3, '{"a","b"}', false, now())`, [alice, S, wc]);
  h.eq('streaks', await h.one(`select * from wordle_streaks($1)`, [alice]), { cur: 3, best: 3 });
  h.eq('bob has no streak', await h.one(`select * from wordle_streaks($1)`, [bob]), { cur: 0, best: 0 });
  await say(alice, wc, '/wordy stats');
  m = await botMsgs(wc);
  h.eq('stats line', m[m.length - 1].content.includes('Played 5 · Won 4 (80%) · Streak 3 · Best streak 3'), true);
  h.eq('stats board lists alice first', m[m.length - 1].content.includes('1. alice · 4 wins / 5 played'), true);
  await h.as(alice);
  h.eq('board for a member', (await h.q(`select user_id, played, wins from wordle_board($1)`, [S])), [{ user_id: alice, played: 5, wins: 4 }, { user_id: bob, played: 1, wins: 0 }]);
  await h.as(outsider);
  h.eq('board hidden from outsiders', (await h.q(`select user_id from wordle_board($1)`, [S])).length, 0);
  await h.fails('clients cannot read the word list', `select word from wordle_words limit 1`);
  await h.fails('clients cannot read games', `select guesses from wordle_games limit 1`);
  await h.fails('clients cannot ask for the answer', `select wordle_answer(wordle_day())`);
  await h.fails('clients cannot post as the bot', `select wordle_say($1, 'hi')`, [wc]);
  await h.admin();

  // The recap for yesterday.
  await h.q(`insert into wordle_games (user_id, day, server_id, channel_id, guesses, won, finished_at) values ($1, wordle_day() - 1, $2, $3, '{"a","b","c","d","e","f"}', false, now())`, [bob, S, wc]);
  const r1 = (await botMsgs(wc)).length;
  h.eq('recap posts in the one server that played', (await h.one(`select wordle_daily_recap() n`)).n, 1);
  m = await botMsgs(wc);
  h.eq('one recap', m.length, r1 + 1);
  h.eq('recap counts', m[m.length - 1].content.includes('2 played, 1 got it (avg 3.0 guesses)'), true);
  h.eq('recap names the quickest', m[m.length - 1].content.includes('Quickest: alice 3/6'), true);
  h.eq('recap hides the word behind a spoiler', /The word was \|\|[A-Z]{5}\|\|\./.test(m[m.length - 1].content), true);
  h.eq('no recap where nobody played', (await botMsgs(wc2)).length, 1);
  // A channel from another server in the config: no recap goes there.
  await h.q(`update server_bots set config = jsonb_build_object('channel_id', $1::text) where server_id = $2`, [general, S2]);
  await h.q(`insert into wordle_games (user_id, day, server_id, channel_id, guesses, won, finished_at) values ($1, wordle_day() - 1, $2, $3, '{"a","b"}', true, now())`, [outsider, S2, wc2]);
  const g1 = (await botMsgs(general)).length;
  h.eq('recap skips a channel that is not the server\'s', (await h.one(`select wordle_daily_recap() n`)).n, 1);
  h.eq('nothing posted across servers', (await botMsgs(general)).length, g1);
  await h.q(`update server_bots set config = jsonb_build_object('channel_id', $1::text) where server_id = $2`, [wc2, S2]);

  // Moving the Wordle channel mid-day: a running game follows.
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, outsider]);
  await say(outsider, wc, '/wordy');
  await h.q(`update server_bots set config = jsonb_build_object('channel_id', $1::text) where server_id = $2`, [general, S]);
  await say(outsider, general, wrong);
  h.eq('bare word in the new channel is ignored until /wordle there', (await h.one(`select guesses from wordle_games where user_id = $1 and day = wordle_day()`, [outsider])).guesses, []);
  await say(outsider, general, '/wordy');
  await say(outsider, general, wrong);
  h.eq('game followed the channel', (await h.one(`select channel_id, guesses from wordle_games where user_id = $1 and day = wordle_day()`, [outsider])), { channel_id: general, guesses: [wrong] });
  await h.q(`update server_bots set config = jsonb_build_object('channel_id', $1::text) where server_id = $2`, [wc, S]);

  // The "/" menu (needs the Bots tab flag as well).
  await h.q(`insert into feature_flags (key, label, mode, servers) values ('bots', 'Bots', 'test', array[$1]::uuid[]) on conflict (key) do update set mode = 'test', servers = array[$1]::uuid[]`, [S]);
  await h.as(alice);
  h.eq('menu shows /wordle', (await h.q(`select name, prefix from server_command_menu($1) where bot_name = 'Wordy' order by name`, [S])), [{ name: 'wordy', prefix: '/' }, { name: 'wordy stats', prefix: '/' }]);
  await h.admin();
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'wordle_bot'`, [S2]);
  await h.as(alice);
  h.eq('menu hides it without the flag', (await h.q(`select 1 from server_command_menu($1) where bot_name = 'Wordy'`, [S])).length, 0);
  await h.admin();
}
