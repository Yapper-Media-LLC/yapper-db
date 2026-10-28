// 269: flags stop leaking. PGlite can't replay the real bootstrap, so bootstrap_v1 / bootstrap_fast are stand-ins that
// carry the live 'flags' line verbatim; 269 must swap that line for my_flags() and leave the rest alone.
// Checked: who gets which flags from my_flags (logged out, plain user, listed user, member of a listed server, admin),
// the test groups stay hidden from non-admins in bootstrap too, only admins can read the table, live flag events carry
// only the key, feature_on stays callable by signed-in people only, user_notes has no anon grant, and 269 re-runs.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.user_notes (owner_id uuid not null, about_id uuid not null, note text, primary key (owner_id, about_id));
alter table public.user_notes enable row level security;
grant select on public.user_notes to anon, authenticated;
-- bootstrap stand-ins with the live 'flags' line (plus something either side that must survive).
create or replace function public.bootstrap_v1() returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select jsonb_build_object(
    'before', 1,
    'flags', (select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) from (select key, label, description, mode, servers, users from public.feature_flags) f),
    'after', 2
  );
$function$;
-- Live broadcast pieces: bc() records what it was handed; bc_flags as live before 269 (whole rows).
create table public.bc_log (n serial, rec jsonb, old_rec jsonb);
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
returns void language plpgsql security definer set search_path to 'public' as $$
begin insert into public.bc_log (rec, old_rec) values (to_jsonb(new), to_jsonb(old)); end $$;
create or replace function public.bc_flags() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public.bc('all', 'flags', tg_op, tg_table_name, tg_table_schema, new, old); return null; end; $$;
create trigger feature_flags_bc after insert or delete or update on public.feature_flags for each row execute function public.bc_flags();
-- The live column grants (098).
grant select (key, label, description, mode, updated_at) on public.feature_flags to anon, authenticated;
create or replace function public.bootstrap_fast() returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
begin
  return jsonb_build_object(
    'fast', true,
    'flags', (select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) from (select key, label, description, mode, servers, users from public.feature_flags) f)
  );
end
$function$;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '269_flags_privacy.sql'), 'utf8');
  await h.db.exec(STANDINS);

  const amy = await h.signup('amy@test.dev', 'amy'); // plain user
  const bob = await h.signup('bob@test.dev', 'bob'); // listed by user id
  const cat = await h.signup('cat@test.dev', 'cat'); // member of a listed server
  const ada = await h.signup('ada@test.dev', 'ada'); // site admin
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [ada]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('t', $1) returning id`, [cat])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('o', $1) returning id`, [ada])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, cat]);
  await h.q(`delete from feature_flags`);
  await h.q(`insert into feature_flags (key, label, description, mode, servers, users) values
    ('live_one', 'Live', 'd', 'everyone', '{}', '{}'),
    ('secret_off', 'Secret', 'roadmap', 'off', '{}', '{}'),
    ('by_user', 'By user', 'd', 'test', '{}', array[$1, $2]::uuid[]),
    ('by_server', 'By server', 'd', 'test', array[$3, $4]::uuid[], '{}'),
    ('age_screen', 'Age screen', 'd', 'test', '{}', '{}')`, [bob, ada, sid, other]);

  await h.db.exec(MIG);
  await h.ok('269 re-runs cleanly', () => h.db.exec(MIG));

  const flags = async (who) => {
    await h.as(who);
    return (await h.q(`select key, servers, users from my_flags() order by key`)).map((r) => [r.key, r.servers, r.users]);
  };

  h.eq('logged out: released flags and age_screen only', (await flags(null)).map((r) => r[0]), ['age_screen', 'live_one']);
  h.eq('plain user: nothing in test or off', (await flags(amy)).map((r) => r[0]), ['age_screen', 'live_one']);
  h.eq('listed user: their test flag, with only their own id', (await flags(bob)).filter((r) => r[0] === 'by_user'),
    [['by_user', [], [bob]]]);
  h.eq('member of a listed server: that flag, with only their server', (await flags(cat)).filter((r) => r[0] === 'by_server'),
    [['by_server', [sid], []]]);
  h.eq('admin: every flag with full groups', await flags(ada), [
    ['age_screen', [], []], ['by_server', [sid, other], []], ['by_user', [], [bob, ada]], ['live_one', [], []], ['secret_off', [], []],
  ]);

  // bootstrap: flags come from my_flags(), the rest of each function is untouched.
  await h.admin();
  const defs = await h.q(`select proname, prosrc from pg_proc where proname in ('bootstrap_v1', 'bootstrap_fast') order by proname`);
  for (const d of defs) {
    h.eq(`${d.proname} reads my_flags()`, d.prosrc.includes('from public.my_flags() f)'), true);
    h.eq(`${d.proname} no longer reads the table`, d.prosrc.includes('from public.feature_flags) f)'), false);
  }
  await h.as(cat);
  const b1 = (await h.one(`select bootstrap_v1() b`)).b;
  h.eq('bootstrap_v1 keeps its other keys', [b1.before, b1.after], [1, 2]);
  h.eq('bootstrap_v1 flags for a member: no other test groups', b1.flags.map((f) => [f.key, f.servers, f.users]).sort(),
    [['age_screen', [], []], ['by_server', [sid], []], ['live_one', [], []]]);
  const bf = (await h.one(`select bootstrap_fast() b`)).b;
  h.eq('bootstrap_fast keeps its other keys', bf.fast, true);
  h.eq('bootstrap_fast hides other people in test groups', JSON.stringify(bf.flags).includes(bob), false);

  await h.admin();
  h.eq('anon has no grant on user_notes', (await h.one(`select has_table_privilege('anon', 'public.user_notes', 'select') ok`)).ok, false);
  h.eq('signed-in people keep theirs', (await h.one(`select has_table_privilege('authenticated', 'public.user_notes', 'select') ok`)).ok, true);

  // The table: admins only.
  await h.as(amy);
  h.eq('plain user reads no rows from the table', (await h.one(`select count(*)::int n from feature_flags`)).n, 0);
  await h.as(bob);
  h.eq('even a tester reads no rows from the table', (await h.one(`select count(*)::int n from feature_flags`)).n, 0);
  await h.as(ada);
  h.eq('admin reads every row', (await h.one(`select count(*)::int n from feature_flags`)).n, 5);
  await h.ok('admin can still switch a flag (Admin -> Features)', () => h.q(`update feature_flags set mode = 'everyone' where key = 'secret_off'`));
  await h.admin();
  h.eq('the admin update landed', (await h.one(`select mode from feature_flags where key = 'secret_off'`)).mode, 'everyone');
  h.eq('anon has no column grants left', (await h.one(
    `select bool_or(has_column_privilege('anon', 'public.feature_flags', a.attname, 'select')) any from pg_attribute a
     where a.attrelid = 'public.feature_flags'::regclass and a.attnum > 0 and not a.attisdropped`)).any, false);

  // Live events: only the key.
  const last = await h.one(`select rec, old_rec from bc_log order by n desc limit 1`);
  h.eq('a flag change broadcasts only its key', [last.rec, last.old_rec], [{ key: 'secret_off' }, null]);
  await h.q(`delete from feature_flags where key = 'secret_off'`);
  h.eq('a deleted flag broadcasts only its key', (await h.one(`select rec from bc_log order by n desc limit 1`)).rec, { key: 'secret_off' });

  // feature_on: not for logged-out people; signed-in people keep it (invoker functions call it as the user).
  h.eq(`anon can't call feature_on`, (await h.one(`select has_function_privilege('anon', 'public.feature_on(text, uuid)', 'execute') ok`)).ok, false);
  h.eq(`signed-in people can call feature_on`, (await h.one(`select has_function_privilege('authenticated', 'public.feature_on(text, uuid)', 'execute') ok`)).ok, true);

  // No definer function hands out the raw table with its test groups any more.
  h.eq('no function selects users from the table', (await h.q(
    `select proname from pg_proc where prosecdef and prosrc ilike '%users from public.feature_flags%'`)).length, 0);
}
