// 246: username holds. PGlite can't replay every migration, so: 001..024, flags (031, 041), stand-ins for live
// pieces 246 runs next to (as live, Oct 18): is_staff (admin or mod), and the daily limit that was made via MCP with
// no migration file (username_changes(user_id, at) + username_change_limit() + trigger profiles_username_limit,
// copied verbatim). Then 246 twice (re-runnable). handle_new_user() and username_taken() come from 246 itself.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;

-- The live daily limit (no migration file).
create table public.username_changes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  at timestamptz not null default now()
);
create index username_changes_user_idx on public.username_changes (user_id, at desc);
alter table public.username_changes enable row level security;
revoke all on public.username_changes from anon, authenticated;
CREATE OR REPLACE FUNCTION public.username_change_limit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if new.username is not distinct from old.username then return new; end if;
  if auth.uid() is null or auth.uid() <> new.id or public.is_staff() then return new; end if;
  if lower(new.username) = lower(old.username) then return new; end if;
  if (select count(*) from public.username_changes c where c.user_id = new.id and c.at > now() - interval '1 day') >= 5 then
    raise exception 'You can change your username 5 times a day. Try again tomorrow' using errcode = 'check_violation';
  end if;
  insert into public.username_changes (user_id) values (new.id);
  if random() < 0.01 then execute 'dele' || 'te from public.username_changes where at < now() - interval ''2 days'''; end if;
  return new;
end $function$;
create trigger profiles_username_limit before update of username on public.profiles
  for each row execute function public.username_change_limit();
`;

const LIMIT = /You can change your username 5 times a day/;
const TAKEN = /^That username is taken$/;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '246_username_holds.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('246 re-runs cleanly', () => h.db.exec(MIG));

  const errOf = async (sql, params = []) => {
    try { await h.db.query(sql, params); return null; } catch (e) { return e.message; }
  };
  const refused = async (name, sql, params, re) => {
    const m = await errOf(sql, params);
    if (!m || !re.test(m)) throw new Error(`✗ ${name}: expected ${re}, got ${m ?? 'success'}`);
    h.passed++;
  };
  const rename = (id, to) => h.q(`update profiles set username = $2 where id = $1`, [id, to]);
  const nameOf = async (id) => { await h.admin(); return (await h.one(`select username from profiles where id = $1`, [id])).username; };
  const holdOf = async (k) => { await h.admin(); return h.one(`select user_id, until > now() active from username_holds where name_key = $1`, [k]); };
  const changes = async (id) => { await h.admin(); return (await h.one(`select count(*)::int n from username_changes where user_id = $1`, [id])).n; };
  const holdCount = async () => { await h.admin(); return (await h.one(`select count(*)::int n from username_holds`)).n; };

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  const dan = await h.signup('dan@test.dev', 'dan');
  const kit = await h.signup('kit@test.dev', 'kit');

  await h.admin();
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'username_limits'`);
  h.eq('flag exists in test mode for the test server and Antic', [flag.mode, flag.servers, flag.users],
    ['test', ['00000000-0000-4000-8000-00000000b001'], ['00000000-0000-4000-8000-00000000a001']]);
  h.eq('one holds trigger, even after re-running', (await h.one(
    `select count(*)::int n from pg_trigger where tgname = 'profiles_username_limit_holds'`)).n, 1);
  h.eq('the live limit fires first (BEFORE triggers go by name)', (await h.q(
    `select tgname from pg_trigger where tgrelid = 'public.profiles'::regclass and tgname like 'profiles_username%' order by tgname`))
    .map((r) => r.tgname), ['profiles_username_limit', 'profiles_username_limit_holds']);
  h.eq('246 leaves the live change log alone', (await h.q(
    `select column_name from information_schema.columns where table_name = 'username_changes' order by ordinal_position`))
    .map((r) => r.column_name), ['user_id', 'at']);

  // Flag off for dan: no holds (the live limit still logs, that's its own business).
  await h.as(dan);
  await h.ok('flag off: change 1', () => rename(dan, 'dan1'));
  await h.ok('flag off: change 2', () => rename(dan, 'dan2'));
  h.eq('flag off: nothing held', await holdCount(), 0);

  // Flag on for amy, bob, cat and kit (test mode, by user).
  await h.admin();
  await h.q(`update feature_flags set users = array[$1, $2, $3, $4]::uuid[] where key = 'username_limits'`, [amy, bob, cat, kit]);

  await h.as(amy);
  await h.ok('change 1', () => rename(amy, 'amy2'));
  await h.ok('change 2', () => rename(amy, 'amy3'));
  h.eq('old names are held for amy', [await holdOf('amy'), await holdOf('amy2')],
    [{ user_id: amy, active: true }, { user_id: amy, active: true }]);
  h.eq('hold lasts 7 days', (await h.one(
    `select until between now() + interval '6 days 23 hours' and now() + interval '7 days 1 minute' ok from username_holds where name_key = 'amy'`)).ok, true);
  h.eq('246 logs nothing itself (only the live limit counts)', await changes(amy), 2);
  await h.as(amy);
  await h.ok('case-only change', () => rename(amy, 'AMY3'));
  await h.ok('saving the same name', () => rename(amy, 'AMY3'));
  h.eq('case-only change: old casing not held', await holdOf('amy3'), undefined);

  // Someone else can't take a held name, in any casing, and the refused try doesn't use up a change.
  const bobBefore = await changes(bob);
  await h.as(bob);
  await refused('held name refused for another user', `update profiles set username = 'amy' where id = $1`, [bob], TAKEN);
  await refused('held name refused in other casing', `update profiles set username = 'Amy2' where id = $1`, [bob], TAKEN);
  h.eq('bob keeps his name', await nameOf(bob), 'bob');
  h.eq('a refused hold logs no change', await changes(bob), bobBefore);
  h.eq('a refused try holds nothing', await holdOf('bob'), undefined);

  // username_taken: true for held names, for anon too.
  await h.as(null);
  h.eq('username_taken: held name', (await h.one(`select username_taken('AMY') t`)).t, true);
  h.eq('username_taken: used name', (await h.one(`select username_taken('bob') t`)).t, true);
  h.eq('username_taken: free name', (await h.one(`select username_taken('nobody_here') t`)).t, false);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'username_limits'`);
  await h.as(null);
  h.eq('username_taken: flag off ignores holds', (await h.one(`select username_taken('amy') t`)).t, false);
  await h.admin();
  await h.q(`update feature_flags set mode = 'test' where key = 'username_limits'`);

  // The owner takes a held name back; the hold ends, the name they leave is held.
  await h.as(amy);
  await h.ok('owner takes their held name back', () => rename(amy, 'amy'));
  h.eq('owner has it again', await nameOf(amy), 'amy');
  h.eq('their hold on it ended', (await holdOf('amy')).active, false);
  h.eq('the name they left is held now', await holdOf('amy3'), { user_id: amy, active: true });

  // The live 5-a-day limit still applies and fires first: a 6th change is refused with no hold written.
  await h.as(kit);
  for (let i = 1; i <= 5; i++) await h.ok(`kit change ${i}`, () => rename(kit, `kit${i}`));
  h.eq('kit: 5 changes logged', await changes(kit), 5);
  h.eq('kit5 not held yet', await holdOf('kit5'), undefined);
  await h.as(kit);
  await refused('6th change refused by the live limit', `update profiles set username = 'kit6' where id = $1`, [kit], LIMIT);
  h.eq('kit keeps kit5', await nameOf(kit), 'kit5');
  h.eq('6th change: no hold written', await holdOf('kit5'), undefined);
  h.eq('6th change: no change logged', await changes(kit), 5);
  await h.as(kit);
  await refused('6th change onto a held name: the limit answers first', `update profiles set username = 'amy3' where id = $1`, [kit], LIMIT);

  // Holds expire.
  await h.admin();
  await h.q(`update username_holds set until = now() - interval '1 second' where name_key = 'amy2'`);
  await h.as(null);
  h.eq('username_taken: expired hold is free', (await h.one(`select username_taken('amy2') t`)).t, false);
  await h.as(bob);
  await h.ok('expired hold: another user can take it', () => rename(bob, 'amy2'));
  h.eq('bob has it', await nameOf(bob), 'amy2');
  h.eq('bob now holds his old name', await holdOf('bob'), { user_id: bob, active: true });

  // Staff and server-side changes aren't held or blocked.
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [cat]);
  await h.as(cat);
  await h.ok('staff may take a held name', () => rename(cat, 'amy3'));
  h.eq('staff change: old name not held', await holdOf('cat'), undefined);
  await h.admin();
  await h.q(`update profiles set username = 'cat' where id = $1`, [cat]);
  await h.ok('server-side rename onto a held name', () => h.q(`update profiles set username = 'bob' where id = $1`, [cat]));
  await h.q(`update profiles set username = 'cat' where id = $1`, [cat]);
  // Someone renaming another person's row (RLS stops this anyway) never holds or blocks.
  await h.as(amy);
  await h.q(`update profiles set username = 'amy3' where id = $1`, [dan]);
  h.eq('a rename of someone else\'s row does nothing', await nameOf(dan), 'dan2');

  // Test mode: people outside the test aren't limited by holds; sign-ups are unchanged.
  await h.as(dan);
  await h.ok('test mode: outsider can take a held name', () => rename(dan, 'amy3'));
  await h.admin();
  await h.q(`update profiles set username = 'dan' where id = $1`, [dan]);
  const eve = await h.signup('eve@test.dev', 'amy3');
  h.eq('test mode: a sign-up still gets a held name', await nameOf(eve), 'amy3');

  // Mode everyone: sign-ups skip held names, a direct insert of a held name is refused.
  await h.q(`update profiles set username = 'eve' where id = $1`, [eve]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'username_limits'`);
  const fay = await h.signup('fay@test.dev', 'AMY3');
  h.eq('everyone: sign-up skips a held name', await nameOf(fay), 'AMY31');
  await h.admin();
  await h.q(`alter table auth.users disable trigger user`);
  const gid = (await h.one(`insert into auth.users (email) values ('h@test.dev') returning id`)).id;
  await h.q(`alter table auth.users enable trigger user`);
  await refused('everyone: a held name is refused on insert, whatever the role',
    `insert into profiles (id, username) values ($1, 'amy3')`, [gid], TAKEN);
  await h.ok('everyone: a free name is fine on insert', () => h.q(`insert into profiles (id, username) values ($1, 'hal')`, [gid]));
  await h.as(dan);
  await refused('everyone: dan gets holds now', `update profiles set username = 'amy3' where id = $1`, [dan], TAKEN);
  await h.admin();
  await h.q(`update feature_flags set mode = 'test' where key = 'username_limits'`);

  // Clients can't touch holds.
  await h.as(bob);
  await refused('people can\'t read holds', `select * from username_holds`, [], /permission denied/);
  await refused('people can\'t write holds', `insert into username_holds (name_key, user_id, until) values ('zz', $1, now() + interval '9 days')`, [bob], /permission denied/);
  await h.as(null);
  await refused('anon can\'t read holds', `select * from username_holds`, [], /permission denied/);

  // Cascade: deleting a profile takes its holds with it.
  await h.admin();
  await h.q(`delete from profiles where id = $1`, [bob]);
  h.eq('cascade on profile delete', (await h.one(`select count(*)::int n from username_holds where user_id = $1`, [bob])).n, 0);

  await h.ok('246 re-runs cleanly after use', () => h.db.exec(MIG));
  h.eq('re-run keeps the holds', (await holdOf('amy3')).active, true);
}
