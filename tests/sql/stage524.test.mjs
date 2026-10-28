// 524: big servers' member lists can't be paged out of server_members; capped lookups by ids / recent joins instead.
// Starts from stage 24 with stand-ins for what came later: servers.member_count, server_members.nickname and the
// webhook_rate counters (155).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('524_member_read_cap.sql');

const STANDINS = String.raw`
alter table public.servers add column if not exists member_count int not null default 0;
alter table public.server_members add column if not exists nickname text;
alter table public.profiles add column if not exists display_name text;
create table if not exists public.webhook_rate (
  k text not null, bucket bigint not null, n int not null default 0, at timestamptz not null default now(),
  primary key (k, bucket)
);
alter table public.webhook_rate enable row level security;
revoke all on public.webhook_rate from public, anon, authenticated;
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
revoke all on function public.webhook_hit(text, int, int) from public, anon, authenticated;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`524 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  const owner = await h.signup('owner@x.test', 'owner');
  const me = await h.signup('me@x.test', 'me');
  const other = await h.signup('other@x.test', 'other');
  const outsider = await h.signup('out@x.test', 'outsider');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('524 runs', () => h.db.exec(MIG));
  await h.ok('524 re-runs cleanly', () => h.db.exec(MIG));

  const big = (await h.one(`insert into public.servers (name, owner_id, member_count) values ('Big', $1, 98000) returning id`, [owner])).id;
  const small = (await h.one(`insert into public.servers (name, owner_id, member_count) values ('Small', $1, 3) returning id`, [owner])).id;
  for (const sid of [big, small]) {
    await h.q(`insert into public.server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '30 days') on conflict do nothing`, [sid, owner]);
    await h.q(`insert into public.server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '10 days') on conflict do nothing`, [sid, me]);
    await h.q(`insert into public.server_members (server_id, user_id, joined_at, nickname) values ($1, $2, now() - interval '1 hour', 'oth') on conflict do nothing`, [sid, other]);
  }
  const count = async (sid) => Number((await h.one(`select count(*) n from public.server_members where server_id = $1`, [sid])).n);

  // The table: whole list in small servers, only your own row in big ones.
  await h.as(me);
  h.eq('small server: every member row readable', await count(small), 3);
  h.eq('big server: only your own row', await count(big), 1);
  h.eq('big server: the one row is yours', (await h.one(`select user_id from public.server_members where server_id = $1`, [big])).user_id, me);
  h.eq('your own memberships still all readable', Number((await h.one(`select count(*) n from public.server_members where user_id = $1`, [me])).n), 2);
  await h.as(outsider);
  h.eq('outsider: nothing in the small server', await count(small), 0);
  h.eq('outsider: nothing in the big server', await count(big), 0);

  // server_members_by_ids
  await h.as(me);
  const byIds = async (sid, ids) => (await h.q(`select user_id, nickname from public.server_members_by_ids($1, $2::uuid[]) order by user_id`, [sid, ids])).map((r) => r.user_id);
  h.eq('by_ids: big server, asked people come back', (await byIds(big, [other, owner])).length, 2);
  h.eq('by_ids: people not in the server are left out', await byIds(big, [outsider]), []);
  h.eq('by_ids: empty list', await byIds(big, []), []);
  await h.fails('by_ids: more than 200 at once refused', `select * from public.server_members_by_ids($1, array(select gen_random_uuid() from generate_series(1, 201)))`, [big]);
  await h.as(outsider);
  h.eq('by_ids: outsider gets nothing', await byIds(big, [me, other, owner]), []);
  await h.as(null);
  await h.fails('by_ids: anon can not call it', `select * from public.server_members_by_ids($1, $2::uuid[])`, [big, [me]]);

  // server_members_since
  await h.as(me);
  const since = async (sid, after) => (await h.q(`select user_id from public.server_members_since($1, $2::timestamptz)`, [sid, after])).map((r) => r.user_id);
  h.eq('since: recent joiner comes back', await since(big, new Date(Date.now() - 86_400_000).toISOString()), [other]);
  h.eq('since: never further back than 2 days', await since(big, '2000-01-01T00:00:00Z'), [other]);
  h.eq('since: null after gives nothing', await since(big, null), []);
  await h.as(outsider);
  h.eq('since: outsider gets nothing', await since(big, '2000-01-01T00:00:00Z'), []);

  // The helpers aren't callable directly.
  await h.as(me);
  await h.fails('member_lookup_ok not callable', `select public.member_lookup_ok($1, 'ml', 1)`, [big]);
  await h.fails('webhook_hit_n not callable', `select public.webhook_hit_n('x', 60, 10, 1)`);
  await h.fails('webhook_rate not readable', `select * from public.webhook_rate`);

  // Limit for by_ids / since in big servers: 1000 people a minute, counted per id asked for. Counters start from
  // zero so the calls above don't count.
  const reset = async (sql = `update public.webhook_rate set n = 0`) => { await h.admin(); await h.db.exec(sql); await h.as(me); };
  const ids200 = `array(select gen_random_uuid() from generate_series(1, 200))`;
  await reset();
  await h.ok('1000 ids in a minute pass (5 calls of 200)', async () => {
    for (let i = 0; i < 5; i++) await h.q(`select * from public.server_members_by_ids($1, ${ids200})`, [big]);
  });
  await h.fails('one more id is refused', `select * from public.server_members_by_ids($1, $2::uuid[])`, [big, [other]]);
  await h.fails('since shares the same limit', `select * from public.server_members_since($1, now() - interval '1 day')`, [big]);
  await h.ok('small servers have no limit', async () => {
    for (let i = 0; i < 10; i++) await h.q(`select * from public.server_members_by_ids($1, ${ids200})`, [small]);
  });
  await h.as(other);
  h.eq('another account has its own limit', (await h.q(`select user_id from public.server_members_by_ids($1, $2::uuid[])`, [big, [me]])).length, 1);

  // The hourly cap (5000) survives the 10-minute cleanups other code runs: rows are stamped with their window's end.
  await reset(`update public.webhook_rate set n = 0 where k like 'ml:m:%'; update public.webhook_rate set n = 4990 where k like 'ml:h:%'`);
  await h.admin();
  const gone = await h.q(`with d as (select * from public.webhook_rate where at < now() - interval '10 minutes') select count(*) n from d`);
  h.eq('a 10-minute cleanup would remove no live counter', Number(gone[0].n), 0);
  h.eq('counter rows are stamped in the future (window end)', (await h.one(`select bool_and(at > now()) v from public.webhook_rate where k like 'ml:%'`)).v, true);
  await h.as(me);
  await h.fails('11 ids past 4990 in the hour are refused', `select * from public.server_members_by_ids($1, array(select gen_random_uuid() from generate_series(1, 11)))`, [big]);
  await h.ok('10 ids still fit in the hour', () => h.q(`select * from public.server_members_by_ids($1, array(select gen_random_uuid() from generate_series(1, 10)))`, [big]));

  // Member search: at most 10 results, 60 searches a minute in big servers, none counted in small ones.
  await h.admin();
  await h.db.exec(`update public.webhook_rate set n = 0`);
  await h.as(me);
  const find = (sid, q, lim = 25) => h.q(`select user_id from public.find_server_members($1, $2, false, $3)`, [sid, q, lim]);
  h.eq('search still finds people', (await find(big, 'ot')).length, 1);
  await h.ok('59 more searches in a minute pass', async () => { for (let i = 0; i < 59; i++) await find(big, 'ow'); });
  await h.fails('the 61st search is refused', `select * from public.find_server_members($1, 'ow', false, 10)`, [big]);
  await h.ok('small servers have no search limit', async () => { for (let i = 0; i < 70; i++) await find(small, 'ow'); });
  await h.as(outsider);
  h.eq('search: outsider gets nothing', await find(big, 'me'), []);
  await h.admin();
  h.eq('search results capped at 10', (await h.one(`select (regexp_match(prosrc, 'least\\(greatest\\(coalesce\\(lim, 10\\), 1\\), (\\d+)\\)'))[1] v from pg_proc where proname = 'find_server_members'`)).v, '10');
}
