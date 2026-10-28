// 268 (applied live as "247_fast_startup" before the number clash was noticed): fast start-up behind flag `fast_startup`. PGlite can't replay the whole schema the real bootstrap reads, so
// the bodies aren't run here (check_function_bodies off while 268 loads; their results were compared live against the
// old functions, Oct 18). What is checked: 268 loads and re-runs, the flag is seeded in test mode, the internal
// helpers can't be called by anyone but the switches, and bootstrap() / unread_counts_v2() take the right path for
// flag off, test (listed user, member of a listed server) and everyone.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

// The live helper 268 calls (no migration file has its current text), copied verbatim.
const STANDINS = `
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (auth.uid() = any(users) or exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers)))) from public.feature_flags where key = k), false);
$$;
`;

// After 268: stub out the bodies so a call shows which path it took.
const STUBS = `
create or replace function public.bootstrap_v1() returns jsonb language sql stable security definer set search_path = public as $$ select '{"path":"v1"}'::jsonb $$;
create or replace function public.bootstrap_fast() returns jsonb language sql stable security definer set search_path = public as $$ select '{"path":"fast"}'::jsonb $$;
create or replace function public.unread_counts_v1() returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
  language sql stable security definer set search_path = public as $$ select '00000000-0000-0000-0000-000000000001'::uuid, 1, false, 0 $$;
create or replace function public.visible_server_channels_fast(sids uuid[]) returns setof public.channels
  language sql stable security definer set search_path = public as $$ select * from public.channels where false $$;
create or replace function public.unread_counts_for(vis public.channels[]) returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
  language sql stable security definer set search_path = public as $$ select '00000000-0000-0000-0000-000000000002'::uuid, cardinality(vis), false, 0 $$;
`;

const INTERNAL = [
  'bootstrap_v1()', 'unread_counts_v1()', 'visible_server_channels_fast(uuid[])',
  'unread_counts_for(public.channels[])', 'bootstrap_fast()',
];

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '268_fast_startup.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(`set check_function_bodies = off;`);
  await h.db.exec(MIG);
  await h.ok('268 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`set check_function_bodies = on;`);

  await h.admin();
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'fast_startup'`);
  h.eq('flag exists in test mode for the test server and Antic', [flag.mode, flag.servers, flag.users],
    ['test', ['00000000-0000-4000-8000-00000000b001'], ['00000000-0000-4000-8000-00000000a001']]);
  h.eq('the switches are plpgsql now', (await h.q(
    `select p.proname, l.lanname from pg_proc p join pg_language l on l.oid = p.prolang
     where p.pronamespace = 'public'::regnamespace and p.proname in ('bootstrap', 'unread_counts_v2') order by 1`)),
    [{ proname: 'bootstrap', lanname: 'plpgsql' }, { proname: 'unread_counts_v2', lanname: 'plpgsql' }]);

  for (const fn of INTERNAL) {
    for (const role of ['anon', 'authenticated', 'service_role']) {
      h.eq(`${role} can't call ${fn}`, (await h.one(
        `select has_function_privilege($1, 'public.${fn}', 'execute') ok`, [role])).ok, false);
    }
  }
  for (const fn of ['bootstrap()', 'unread_counts_v2()']) {
    h.eq(`signed-in people can call ${fn}`, (await h.one(`select has_function_privilege('authenticated', 'public.${fn}', 'execute') ok`)).ok, true);
    h.eq(`logged-out people can't call ${fn}`, (await h.one(`select has_function_privilege('anon', 'public.${fn}', 'execute') ok`)).ok, false);
  }

  await h.db.exec(STUBS);
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('t', $1) returning id`, [cat])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, cat]);
  await h.q(`update feature_flags set users = array[$1]::uuid[], servers = array[$2]::uuid[] where key = 'fast_startup'`, [amy, sid]);

  const boot = async (who) => { await h.as(who); return (await h.one(`select bootstrap() b`)).b.path; };
  const unread = async (who) => { await h.as(who); return (await h.one(`select channel_id from unread_counts_v2()`)).channel_id; };
  const V1 = '00000000-0000-0000-0000-000000000001';
  const FAST = '00000000-0000-0000-0000-000000000002';

  h.eq('test mode: listed user gets the fast path', [await boot(amy), await unread(amy)], ['fast', FAST]);
  h.eq('test mode: member of a listed server gets the fast path', [await boot(cat), await unread(cat)], ['fast', FAST]);
  h.eq('test mode: everyone else keeps the old path', [await boot(bob), await unread(bob)], ['v1', V1]);

  await h.as(bob);
  for (const fn of ['bootstrap_v1()', 'bootstrap_fast()', 'unread_counts_v1()', 'visible_server_channels_fast(null)']) {
    await h.fails(`a signed-in person can't call ${fn} directly`, `select * from public.${fn}`);
  }
  await h.fails(`a signed-in person can't hand unread_counts_for their own channel list`,
    `select * from public.unread_counts_for(array(select c from public.channels c))`);

  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'fast_startup'`);
  h.eq('everyone: fast path for all', [await boot(bob), await unread(bob)], ['fast', FAST]);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'fast_startup'`);
  h.eq('off: old path, even for listed people', [await boot(amy), await unread(amy), await boot(cat)], ['v1', V1, 'v1']);
}
