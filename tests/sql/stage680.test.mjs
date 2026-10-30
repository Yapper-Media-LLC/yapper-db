// 680: quiz polls + voter list (flag quiz_polls). The right answer can't be read before you may see it: not from the
// table, not from poll_results / poll_view / poll_voters, not from the live broadcast. vote_quiz answers once and
// returns the reveal. Old polls and plain create_poll polls stay anonymous; poll_voters pages and respects that.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '680_quiz_polls.sql'), 'utf8');

// Polls and ballots as live (032 + 151 + 420), a create_poll stand-in, bc() writing to a log.
const STANDINS = String.raw`
alter table public.channels add column if not exists server_id uuid;
alter table public.channels drop constraint if exists channels_kind_check;
alter table public.channels drop constraint if exists channels_server_id_fkey;
alter table public.channels drop constraint if exists channels_dm_key_check;
create table if not exists public.t680 (k text primary key);
create or replace function public.can_access_channel(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.t680 where k = 'hidden:' || cid::text) $$;
create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(), message_id uuid, channel_id uuid not null references public.channels (id) on delete cascade,
  question text not null default 'q', options jsonb not null default '[]', multi boolean not null default false,
  closes_at timestamptz, created_by uuid, created_at timestamptz not null default now());
alter table public.polls enable row level security;
create policy "members read polls" on public.polls for select to authenticated using (public.can_access_channel(channel_id));
grant select on public.polls to authenticated;
create table if not exists public.poll_ballots (
  poll_id uuid not null references public.polls (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  option_ids text[] not null default '{}', created_at timestamptz not null default now(),
  primary key (poll_id, user_id));
alter table public.poll_ballots enable row level security;
create policy "own ballot read" on public.poll_ballots for select to authenticated using (user_id = (select auth.uid()));
grant select on public.poll_ballots to authenticated;
create table if not exists public.bc_log (topic text, op text, rec jsonb, old jsonb);
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
returns void language plpgsql security definer set search_path = public as $f$
begin
  insert into public.bc_log values (topic_name, operation,
    case when new is null then null else to_jsonb(new) end, case when old is null then null else to_jsonb(old) end);
end $f$;
create or replace function public.create_poll(cid uuid, question text, opts text[], multi boolean default false, hours integer default 24)
returns uuid language plpgsql security definer set search_path = public as $f$
declare o jsonb := '[]'; i int; pid uuid;
begin
  for i in 1 .. array_length(opts, 1) loop o := o || jsonb_build_object('id', i::text, 'text', opts[i]); end loop;
  insert into public.polls (channel_id, question, options, multi, closes_at, created_by)
  values (cid, question, o, multi, case when hours > 0 then now() + make_interval(hours => hours) end, auth.uid()) returning id into pid;
  return pid;
end $f$;
-- 151's vote_poll (plain polls), to check it can't change a quiz answer.
create or replace function public.vote_poll(pid uuid, option_ids text[]) returns void language plpgsql security definer set search_path = public as $f$
begin
  if coalesce(array_length(option_ids, 1), 0) = 0 then
    delete from public.poll_ballots where poll_id = pid and user_id = auth.uid(); return;
  end if;
  insert into public.poll_ballots (poll_id, user_id, option_ids) values (pid, auth.uid(), option_ids)
  on conflict (poll_id, user_id) do update set option_ids = excluded.option_ids, created_at = now();
end $f$;
create trigger poll_ballots_broadcast after insert or update or delete on public.poll_ballots
  for each row execute function public.broadcast_poll_ballot_standin();
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`680 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  // The broadcast trigger points at 680's function; a placeholder so the stand-ins load first.
  await h.db.exec(`create or replace function public.broadcast_poll_ballot_standin() returns trigger language plpgsql as $$ begin return null; end $$;`);
  await h.db.exec(STANDINS);
  await h.ok('680 runs', () => h.db.exec(MIG));
  await h.ok('680 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`drop trigger poll_ballots_broadcast on public.poll_ballots;
    create trigger poll_ballots_broadcast after insert or update or delete on public.poll_ballots
    for each row execute function public.broadcast_poll_ballot();`);

  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'quiz_polls'`);
  h.eq('flag is test mode', flag.mode, 'test');
  h.eq('flag test server', flag.servers, ['00000000-0000-4000-8000-00000000b001']);
  h.eq('flag test user', flag.users, ['00000000-0000-4000-8000-00000000a001']);
  h.eq('RLS on poll_answers', (await h.one(`select relrowsecurity r from pg_class where oid = 'public.poll_answers'::regclass`)).r, true);

  const amy = await h.signup('amy680@x.test', 'amy680'); // creator
  const bob = await h.signup('bob680@x.test', 'bob680');
  const cat = await h.signup('cat680@x.test', 'cat680');
  const dan = await h.signup('dan680@x.test', 'dan680');
  await h.admin();
  const SID = '00000000-0000-4000-8000-00000000b001';
  const OFF = '00000000-0000-0000-0000-000000000680';
  const ch = (await h.one(`insert into channels (kind, server_id) values ('text', $1) returning id`, [SID])).id;
  const off = (await h.one(`insert into channels (kind, server_id) values ('text', $1) returning id`, [OFF])).id;
  const hidden = (await h.one(`insert into channels (kind, server_id) values ('text', $1) returning id`, [SID])).id;
  await h.q(`insert into t680 values ($1)`, ['hidden:' + hidden]);

  // Old poll from before 680: anonymous.
  const old = (await h.one(`insert into polls (channel_id, options) values ($1, '[{"id":"1","text":"a"},{"id":"2","text":"b"}]') returning id, anonymous, quiz`, [ch]));
  h.eq('old polls stay anonymous and not quiz', [old.anonymous, old.quiz], [true, false]);

  // ---------- creating ----------
  await h.as(amy);
  await h.fails('flag off server: no create_poll_ex', `select create_poll_ex($1, 'q', '{a,b}', false, 24, true, '{1}', 'vote', false)`, [off]);
  await h.fails('quiz needs a right answer', `select create_poll_ex($1, 'q', '{a,b}', false, 24, true, '{}', 'vote', false)`, [ch]);
  await h.fails('right answer must be an option', `select create_poll_ex($1, 'q', '{a,b}', false, 24, true, '{3}', 'vote', false)`, [ch]);
  await h.fails('not every answer can be right', `select create_poll_ex($1, 'q', '{a,b}', false, 24, true, '{1,2}', 'vote', false)`, [ch]);
  await h.fails('reveal on close needs an end', `select create_poll_ex($1, 'q', '{a,b}', false, 0, true, '{1}', 'close', false)`, [ch]);
  await h.fails('bad reveal value', `select create_poll_ex($1, 'q', '{a,b}', false, 24, true, '{1}', 'later', false)`, [ch]);
  const quiz = (await h.one(`select create_poll_ex($1, 'Capital of France?', '{Paris,Rome,Lyon}', false, 24, true, '{1}', 'vote', false) id`, [ch])).id;
  const closeQuiz = (await h.one(`select create_poll_ex($1, 'Pick primes', '{2,3,4}', true, 24, true, '{1,2}', 'close', true) id`, [ch])).id;
  const plain = (await h.one(`select create_poll_ex($1, 'Pizza?', '{yes,no}', false, 24, false, '{}', 'vote', false) id`, [ch])).id;
  const plainAnon = (await h.one(`select create_poll($1, 'Old client', '{yes,no}', false, 24) id`, [ch])).id;
  const row = await h.one(`select quiz, reveal, anonymous from polls where id = $1`, [quiz]);
  h.eq('quiz row', [row.quiz, row.reveal, row.anonymous], [true, 'vote', false]);
  h.eq('plain create_poll stays anonymous', (await h.one(`select anonymous from polls where id = $1`, [plainAnon])).anonymous, true);

  // ---------- the answer doesn't leak ----------
  await h.as(bob);
  await h.fails('poll_answers is not readable', `select * from poll_answers`);
  await h.fails('poll_visible is internal', `select poll_visible(p) from polls p`);
  h.eq('polls row has no answer column', Object.keys(await h.one(`select * from polls where id = $1`, [quiz])).some((k) => /correct|answer/.test(k)), false);
  let v = (await h.one(`select poll_view($1) v`, [quiz])).v;
  h.eq('before voting: hidden, no answer, no right count', [v.visible, v.correct, v.right, v.you_right, v.voted], [false, null, null, null, false]);
  await h.as(amy);
  v = (await h.one(`select poll_view($1) v`, [quiz])).v;
  h.eq('creator sees the answer', [v.visible, v.correct], [true, ['1']]);

  await h.as(cat);
  v = (await h.one(`select vote_quiz($1, '{2}') v`, [quiz])).v;
  h.eq('cat votes wrong: reveal in the response', [v.visible, v.correct, v.you_right, v.right, v.total], [true, ['1'], false, 0, 1]);
  await h.fails('cat cannot answer again', `select vote_quiz($1, '{1}')`, [quiz]);
  await h.fails('vote_poll cannot switch a quiz answer', `select vote_poll($1, '{1}')`, [quiz]);
  await h.fails('vote_poll cannot take back a quiz answer', `select vote_poll($1, '{}')`, [quiz]);

  await h.as(bob);
  v = (await h.one(`select poll_view($1) v`, [quiz])).v;
  h.eq('bob still sees nothing after cat voted', [v.visible, v.correct], [false, null]);
  const pr = await h.q(`select option_id, votes from poll_results($1) order by option_id`, [quiz]);
  h.eq('poll_results gives 0 votes before you vote', pr.map((r) => Number(r.votes)), [0, 0, 0]);
  await h.fails('bob cannot list voters before answering', `select * from poll_voters($1, '2')`, [quiz]);
  await h.admin();
  await h.q(`delete from bc_log`);
  await h.as(bob);
  v = (await h.one(`select vote_quiz($1, '{1}') v`, [quiz])).v;
  h.eq('bob right', [v.you_right, v.right, v.total], [true, 1, 2]);
  await h.admin();
  const log = await h.q(`select topic, rec -> 'option_ids' opts, rec ->> 'user_id' u from bc_log order by topic`);
  h.eq('quiz broadcast: channel copy without picks or voter', log.map((l) => [l.topic, l.opts, l.u]),
    [['chan:' + ch, [], null], ['user:' + bob, ['1'], bob]]);
  await h.as(bob);
  h.eq('after voting: real counts', (await h.q(`select votes from poll_results($1) order by option_id`, [quiz])).map((r) => Number(r.votes)), [1, 1, 0]);
  h.eq('voters of option 2 (not anonymous)', (await h.q(`select user_id from poll_voters($1, '2')`, [quiz])).map((r) => r.user_id), [cat]);

  // Reveal on close: voting shows nothing until it ends, even the voter's own result.
  await h.as(dan);
  v = (await h.one(`select vote_quiz($1, '{1,2}') v`, [closeQuiz])).v;
  h.eq('close quiz: voted but hidden', [v.voted, v.visible, v.correct, v.you_right], [true, false, null, null]);
  await h.fails('close quiz is anonymous: no voters', `select * from poll_voters($1, '1')`, [closeQuiz]);
  await h.admin();
  await h.q(`update polls set closes_at = now() - interval '1 minute' where id = $1`, [closeQuiz]);
  await h.as(dan);
  v = (await h.one(`select poll_view($1) v`, [closeQuiz])).v;
  h.eq('close quiz after the end: exact set is right', [v.visible, v.correct, v.you_right, v.right], [true, ['1', '2'], true, 1]);
  await h.as(bob);
  v = (await h.one(`select poll_view($1) v`, [closeQuiz])).v;
  h.eq('non voter sees it after the end too', [v.visible, v.voted, v.you_right], [true, false, null]);
  await h.fails('no voting after the end', `select vote_quiz($1, '{1,2}')`, [closeQuiz]);

  // ---------- plain polls and the voter list ----------
  await h.fails('vote_quiz is only for quizzes', `select vote_quiz($1, '{1}')`, [plain]);
  await h.as(bob); await h.q(`select vote_poll($1, '{1}')`, [plain]);
  await h.as(cat); await h.q(`select vote_poll($1, '{1}')`, [plain]);
  await h.as(dan); await h.q(`select vote_poll($1, '{1}')`, [plain]);
  await h.as(dan); await h.q(`select vote_poll($1, '{2}')`, [plain]);
  await h.as(dan); await h.q(`select vote_poll($1, '{}')`, [plain]);
  h.eq('plain poll votes can still change and go', (await h.q(`select votes from poll_results($1) order by option_id`, [plain])).map((r) => Number(r.votes)), [2, 0]);
  await h.admin();
  await h.q(`update poll_ballots set created_at = now() - interval '1 hour' where poll_id = $1 and user_id = $2`, [plain, bob]);
  await h.as(amy);
  const page1 = await h.q(`select user_id, voted_at from poll_voters($1, '1', null, null, 1)`, [plain]);
  h.eq('page 1: newest first', page1.map((r) => r.user_id), [cat]);
  const page2 = await h.q(`select user_id, voted_at from poll_voters($1, '1', $2, $3, 1)`, [plain, page1[0].voted_at, page1[0].user_id]);
  h.eq('page 2', page2.map((r) => r.user_id), [bob]);
  h.eq('page 3 empty', (await h.q(`select user_id from poll_voters($1, '1', $2, $3, 1)`, [plain, page2[0].voted_at, bob])).length, 0);
  await h.fails('anonymous poll: no voters', `select * from poll_voters($1, '1')`, [plainAnon]);
  await h.fails('old poll: no voters', `select * from poll_voters($1, '1')`, [old.id]);
  await h.as(null);
  await h.fails('anon cannot list voters', `select * from poll_voters($1, '1')`, [plain]);
  await h.fails('anon cannot view', `select poll_view($1)`, [quiz]);

  // Can't see the channel: nothing.
  await h.admin();
  const hq = (await h.one(`insert into polls (channel_id, options, quiz, anonymous) values ($1, '[{"id":"1","text":"a"},{"id":"2","text":"b"}]', true, false) returning id`, [hidden])).id;
  await h.q(`insert into poll_answers values ($1, '{1}')`, [hq]);
  await h.as(bob);
  await h.fails('hidden channel: no view', `select poll_view($1)`, [hq]);
  await h.fails('hidden channel: no vote', `select vote_quiz($1, '{1}')`, [hq]);
  await h.fails('hidden channel: no voters', `select * from poll_voters($1, '1')`, [hq]);

  // Cascades still work through the lock: a voter deleting their own account (delete_my_account runs as them).
  await h.admin();
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [cat]);
  await h.ok('a quiz voter can still delete their account', () => h.q(`delete from auth.users where id = $1`, [cat]));
  await h.admin();
  h.eq('their ballot went with it', (await h.q(`select 1 from poll_ballots where user_id = $1`, [cat])).length, 0);
  await h.ok('deleting a quiz poll takes its ballots', () => h.q(`delete from polls where id = $1`, [quiz]));
  h.eq('answers gone too', (await h.q(`select 1 from poll_answers where poll_id = $1`, [quiz])).length, 0);
}
