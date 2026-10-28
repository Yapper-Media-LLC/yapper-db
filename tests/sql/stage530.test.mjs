// 530: names of deleted accounts with a mod history are held (flag deleted_name_hold), and name filter v2
// (flag name_filter_v2): n-word and rape words in six languages, without refusing grapes or therapist.
// Starts from stage 24 with stand-ins for the live pieces (unaccent, fold_fancy, has_slur, is_staff, the mod tables).
// slur_text / has_slur_plain come from 430, the old bad_name from 156 + 378, no_bad_names is the live text (Oct 26).
// Test words are rot13 (Latin) or \u escapes (Cyrillic, Arabic), so this file doesn't spell any slur.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const cut = (src, from, to) => { const i = src.indexOf(from); const j = src.indexOf(to, i + from.length); if (i < 0 || j < 0) throw new Error(`cut: ${from} not found`); return src.slice(i, j + to.length); };
const r13 = (s) => s.replace(/[a-z]/gi, (c) => String.fromCharCode((c <= 'Z' ? 65 : 97) + ((c.toLowerCase().charCodeAt(0) - 97 + 13) % 26)));
const MIG = mig('530_name_holds_and_filter.sql');

const BAD_NAME_PLAIN_OLD = cut(mig('156_sexual_spam.sql'), 'create or replace function public.bad_name', '$$;')
  .replace('public.bad_name(t text)', 'public.bad_name_plain(t text)');
const BAD_NAME_OLD = cut(mig('378_bug_fixes_1021.sql'), 'create or replace function public.bad_name(t text)', '$function$;');

const ANTIC = '00000000-0000-4000-8000-00000000a001';

const STANDINS = String.raw`
set check_function_bodies = off;
create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$
  select translate(t, 'áàâäãéèêëíìîïóòôöõúùûüñçÁÀÂÄÉÈÊËÍÌÎÏÓÒÔÖÚÙÛÜÑÇ', 'aaaaaeeeeiiiiooooouuuuncAAAAEEEEIIIIOOOOUUUUNC') $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable set search_path = public as $$ select normalize(coalesce(t, ''), NFKC) $$;
create or replace function public.has_slur(t text) returns boolean language sql immutable as $$ select public.has_slur_plain(t) $$;
create or replace function public.is_staff() returns boolean language sql stable as $$ select coalesce(current_setting('test.staff', true), '') = 'on' $$;
create or replace function public.username_stale_hold(uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.ban_email_hash(p_email text) returns text language sql immutable as $$ select md5(lower(p_email)) $$;
alter table public.profiles add column if not exists display_name text;
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.username_holds (name_key text primary key, user_id uuid not null, until timestamptz not null);
create table if not exists public.mod_log (
  id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
  target_id uuid references public.profiles (id) on delete set null, reason text not null default '',
  created_at timestamptz not null default now());
create table if not exists public.mod_notes (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles (id) on delete cascade,
  author uuid, body text not null, created_at timestamptz not null default now());
create table if not exists public.user_warnings (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles (id) on delete cascade,
  by uuid, reason text not null, created_at timestamptz not null default now());
create table if not exists public.login_attempts (username text, ip text, ok boolean, at timestamptz default now());
create table if not exists public.ban_leftovers (id bigint generated always as identity primary key, ip text, email_hash text, until timestamptz not null);

-- Old version of profile_custom_guard: the same bad_name( calls as live, the rest left out.
create or replace function public.profile_custom_guard() returns trigger language plpgsql set search_path to 'public' as $function$
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and public.bad_name(new.username) then
    raise exception 'That username isn''t allowed on Yapper. Pick another.';
  end if;
  if new.display_name is not null and (tg_op = 'INSERT' or new.display_name is distinct from old.display_name)
     and public.bad_name(new.display_name) then
    raise exception 'That display name isn''t allowed';
  end if;
  return new;
end;
$function$;
create trigger profiles_custom_guard before insert or update on public.profiles for each row execute function public.profile_custom_guard();

-- Live no_bad_names (Oct 26).
CREATE OR REPLACE FUNCTION public.no_bad_names()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare col text; val text; was text;
begin
  foreach col in array tg_argv loop
    val := to_jsonb(new) ->> col;
    was := case when tg_op = 'UPDATE' then to_jsonb(old) ->> col else null end;
    if val is not null and (was is null or lower(val) <> lower(was)) and public.bad_name(val) then
      raise exception 'That name isn''t allowed on Yapper. Pick another.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end; $function$;
create trigger profiles_no_bad_names before insert or update of username on public.profiles for each row execute function public.no_bad_names('username');
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`530 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('430_filter_bypasses.sql'));
  await h.db.exec(BAD_NAME_PLAIN_OLD);
  await h.db.exec(BAD_NAME_OLD);
  await h.ok('530 runs', () => h.db.exec(MIG));
  await h.ok('530 re-runs cleanly', () => h.db.exec(MIG));

  const fdef = async (f) => (await h.one(`select pg_get_functiondef($1::regprocedure) d`, [f])).d;
  h.eq('profile_custom_guard calls bad_name_for_me', (await fdef('public.profile_custom_guard()')).split('public.bad_name_for_me(').length - 1, 2);
  h.eq('no_bad_names calls bad_name_for_me', (await fdef('public.no_bad_names()')).split('public.bad_name_for_me(').length - 1, 1);
  h.eq('no bare bad_name( left in the guards', /public\.bad_name\(/.test((await fdef('public.profile_custom_guard()')) + (await fdef('public.no_bad_names()'))), false);
  h.eq('flags start in test', (await h.q(`select key, mode from public.feature_flags where key in ('deleted_name_hold', 'name_filter_v2') order by key`)).map((r) => r.mode), ['test', 'test']);

  // ---------- name filter v2 ----------
  h.eq('ru_latin spells Cyrillic by sound, both cases', (await h.one(`select public.ru_latin($1) v`, ['\u041F\u0440\u0438\u0432\u0435\u0442 \u043C\u0438\u0440 \u0451\u0436\u044C'])).v, 'privet mir ez');
  const v2 = async (t) => (await h.one(`select public.bad_name_v2($1) v`, [t])).v;
  const v1 = async (t) => (await h.one(`select public.bad_name($1) v`, [t])).v;

  const REFUSED = {
    // English n-word spellings
    'q for g': r13('avddn'), 'q for g, leet hard r': r13('a1dd3e'), 'hard r with u': r13('avtthe'), 'caps hard r with u': r13('AVTTHE'),
    'vowel-dropped r': r13('avtte'), 'b for g': r13('avoon'), 'phonetic': r13('xarrtebj'), 'still the plain one': r13('avttre'),
    // German, French, Spanish
    'German': r13('artre'), 'German caps': r13('Artre'), 'German glued': r13('qhzzre_artre'), 'German plural': r13('Artrea'),
    'French accented': 'nègre', 'French f.': r13('arterffr'), 'Spanish': r13('artengn'),
    // rape words
    'rape': r13('encr'), 'raping': r13('encvat'), 'rapist': r13('encvfg'), 'raper': r13('encre'), 'raped': r13('encrq'),
    'rapes glued': r13('vybirencrf'), 'leet r4p3': r13('e4c3'), 'R@PE': r13('E@CR'), 'spaced out': r13('e n c r'),
    'the_rapist': r13('gur_encvfg'), 'frape': r13('sencr'), 'masked': r13('e*cr'), 'rapist with digits': r13('encvfg69'),
    'Spanish rapist': r13('ivbynqbe'), 'Spanish rapist leet': r13('i1bynq0e'), 'Spanish rape': r13('ivbynpvóa'), 'Spanish to rape': r13('ivbyne'),
    'French rapist': r13('ivbyrhe'), 'French rape': r13('ivby'), 'German rapist': r13('Iretrjnygvtre'),
    'Russian, Latin letters': r13('anfvyavx'), 'Arabic, Latin letters': r13('vtugvfno'),
    // Cyrillic
    'Cyrillic hard r': '\u043D\u0438\u0433\u0433\u0435\u0440', 'Cyrillic caps': '\u041D\u0418\u0413\u0413\u0415\u0420',
    'Cyrillic one g': '\u043D\u0438\u0433\u0435\u0440', 'Cyrillic -a': '\u043D\u0438\u0433\u0433\u0430',
    'Cyrillic negr': '\u043D\u0435\u0433\u0440', 'Cyrillic negry': '\u041D\u0435\u0433\u0440\u044B',
    'Cyrillic n with Latin rest': '\u043D' + r13('vttre'),
    'Cyrillic rapist': '\u043D\u0430\u0441\u0438\u043B\u044C\u043D\u0438\u043A', 'Cyrillic rape': '\u0438\u0437\u043D\u0430\u0441\u0438\u043B\u043E\u0432\u0430\u043D\u0438\u0435',
    // Arabic
    'Arabic -a': '\u0646\u064A\u0642\u0627', 'Arabic -r': '\u0646\u064A\u063A\u0631', 'Arabic with tatweel': '\u0646\u0640\u064A\u0640\u0642\u0640\u0627',
    'Arabic with harakat': '\u0646\u0650\u064A\u0642\u064E\u0627', 'Arabic presentation forms': '\uFEE7\uFEF4\uFED8\uFE8E',
    'Arabic zinji': '\u0632\u0646\u062C\u064A', 'Arabic rape': '\u0627\u063A\u062A\u0635\u0627\u0628', 'Arabic rapist': '\u0645\u063A\u062A\u0635\u0628',
    // the old list still works
    'old list word': 'hitler_fan',
  };
  for (const [what, t] of Object.entries(REFUSED)) h.eq(`v2 refuses: ${what}`, await v2(t), true);

  const ALLOWED = ['Grapes', 'grape_juice', 'drapery', 'Trapeze', 'scraper', 'therapist', 'Physiotherapist', 'parapet', 'sarape',
    'rapper', 'rapero', 'rapera', 'rapeando', 'mr_ape', 'Viola', 'violet', 'violin', 'Violeta', 'violence', 'violation',
    'Niger', 'Nigeria', 'negro', 'Negrete', 'Negroni', 'Negeri_Sembilan', 'reneger', 'Danneger', 'Spinneger', 'Kenegery', 'Snegera', 'gat_' + r13('arter'), 'vi_' + r13('arter'), 'one_gerbil', 'niqab', 'Snack', 'eggnog',
    '\u043A\u043D\u0438\u0433\u0430', '\u043D\u0435\u0433\u0440\u043E\u043C\u043A\u043E', '\u043D\u0435\u0433\u0440\u0430\u043C\u043E\u0442\u043D\u044B\u0439',
    '\u041D\u0438\u0433\u0435\u0440\u0438\u044F', '\u043D\u0430\u0441\u0438\u043B\u0438\u0435', '\u041F\u0440\u0438\u0432\u0435\u0442',
    '\u0623\u0646\u064A\u0642\u0629', '\u0646\u0642\u0627\u0628', '\u0646\u064A\u0642\u0627\u0628', '\u0646\u064A\u062C\u064A\u0631\u064A\u0627',
    '\u0639\u0628\u062F\u0627\u0644\u0644\u0647', '\u0632\u0646\u062C\u0628\u064A\u0644', '\u0645\u062D\u0645\u062F'];
  for (const t of ALLOWED) h.eq(`v2 allows "${t}"`, await v2(t), false);
  for (const t of ['Grapes', 'drapery', 'Trapeze', 'scraper', 'therapist']) h.eq(`old bad_name refused "${t}" (the false positive v2 fixes)`, await v1(t), true);

  // ---------- holds + flags: people ----------
  const mk = async (id, email, username) => {
    await h.admin();
    return (await h.one(`insert into auth.users (id, email, raw_user_meta_data) values (coalesce($1::uuid, gen_random_uuid()), $2, $3::jsonb) returning id`,
      [id, email, JSON.stringify({ username })])).id;
  };
  const antic = await mk(ANTIC, 'antic@example.com', 'antic');
  const erin = await mk(null, 'erin@example.com', 'erin');
  const dana = await mk(null, 'dana@example.com', 'dana');

  // bad_name_for_me follows the flag: Antic (in the test) gets v2, others the old filter.
  const forMe = async (uid, t) => { if (uid) await h.as(uid); else await h.admin(); const v = (await h.one(`select public.bad_name_for_me($1) v`, [t])).v; await h.admin(); return v; };
  h.eq('tester: grapes allowed', await forMe(antic, 'Grapes'), false);
  h.eq('tester: Spanish rapist refused', await forMe(antic, r13('ivbynqbe')), true);
  h.eq('others: old filter (grapes refused)', await forMe(erin, 'Grapes'), true);
  h.eq('others: old filter (Spanish rapist not known yet)', await forMe(erin, r13('ivbynqbe')), false);
  h.eq('sign-up (no caller) uses the old filter in test', await forMe(null, 'Grapes'), true);

  const rename = async (uid, name) => { await h.as(uid); try { await h.db.query(`update public.profiles set username = $1 where id = $2`, [name, uid]); return 'ok'; } catch (e) { return e.message; } finally { await h.admin(); } };
  const display = async (uid, name) => { await h.as(uid); try { await h.db.query(`update public.profiles set display_name = $1 where id = $2`, [name, uid]); return 'ok'; } catch (e) { return e.message; } finally { await h.admin(); } };
  h.eq('tester can be grapes', await rename(antic, 'grapes'), 'ok');
  h.eq('tester can be therapist', await rename(antic, 'therapist'), 'ok');
  h.eq('tester cannot be a Spanish rapist', /allowed/.test(await rename(antic, r13('ivbynqbe'))), true);
  h.eq('tester display name in Cyrillic refused', /allowed/.test(await display(antic, '\u043D\u0430\u0441\u0438\u043B\u044C\u043D\u0438\u043A')), true);
  h.eq('tester display name Arabic refused', /allowed/.test(await display(antic, '\u0645\u063A\u062A\u0635\u0628')), true);
  h.eq('tester display name Muhammad ok', await display(antic, '\u0645\u062D\u0645\u062F'), 'ok');
  h.eq('outside the test, grapes still refused (old filter)', /allowed/.test(await rename(erin, 'grapes2')), true);

  // ---------- holds ----------
  const bob = await mk(null, 'bob@example.com', 'bob');     // banned for good, warned
  const carl = await mk(null, 'carl@example.com', 'carl');  // a timeout, never banned
  const fred = await mk(null, 'fred@example.com', 'fred');  // banned for 3 more days
  const gus = await mk(null, 'gus@example.com', 'gus');     // nothing on record
  const ivan = await mk(null, 'ivan@example.com', 'ivan');  // timed out, renamed from ivy a day ago
  await h.db.query(`insert into public.username_holds (name_key, user_id, until) values ('ivy', $1, now() + interval '6 days')`, [ivan]);
  await h.db.query(`insert into public.site_bans (user_id, reason) values ($1, 'raiding the HQ')`, [bob]);
  await h.db.query(`insert into public.site_bans (user_id, reason, expires_at) values ($1, 'spam', now() + interval '3 days')`, [fred]);
  await h.db.query(`insert into public.user_warnings (user_id, reason) values ($1, 'slurs'), ($1, 'more slurs')`, [bob]);
  await h.db.query(`insert into public.mod_log (action, target_id) values ('ban', $1), ('warn', $1), ('timeout', $2), ('timeout', $2), ('verify', $3), ('timeout', $4)`, [bob, carl, gus, ivan]);

  await h.as(erin);
  await h.fails('users cannot call keep_deleted_name', `select public.keep_deleted_name($1)`, [erin]);
  await h.fails('users cannot read deleted_name_holds', `select * from public.deleted_name_holds`);
  await h.admin();

  for (const u of [bob, carl, fred, gus, ivan]) {
    await h.db.query(`select public.keep_ban_leftovers($1)`, [u]);
    await h.db.query(`delete from auth.users where id = $1`, [u]);
  }
  const holds = Object.fromEntries((await h.q(`select name_key, why, old_user_id, round(extract(epoch from until - now()) / 86400) days from public.deleted_name_holds`)).map((r) => [r.name_key, r]));
  h.eq('held: bob, carl, fred, ivan and his old name ivy; not gus', Object.keys(holds).sort(), ['bob', 'carl', 'fred', 'ivan', 'ivy']);
  h.eq('old name held as long as the last one', [holds.ivy.old_user_id, Number(holds.ivy.days)], [ivan, 90]);
  h.eq('bob held a year (permanent ban)', Number(holds.bob.days), 365);
  h.eq('carl held 90 days (mod log only)', Number(holds.carl.days), 90);
  h.eq('fred held 90 days (ban ends sooner)', Number(holds.fred.days), 90);
  h.eq('bob summary', holds.bob.why, 'site-banned for good: raiding the HQ; 2 warnings; mod log: ban x1');
  h.eq('carl summary', holds.carl.why, 'mod log: timeout x2');
  h.eq('row outlives the account', holds.bob.old_user_id, bob);

  // test mode: sign-ups aren't refused but get a note; renames refused only for testers.
  h.eq('test: sign-up form still sees bob as free', (await h.one(`select public.srv_username_taken('BOB') v`)).v, false);
  const zed = await mk(null, 'zed@example.com', 'bob');
  h.eq('test: new account gets bob', (await h.one(`select username from public.profiles where id = $1`, [zed])).username, 'bob');
  const zNote = await h.one(`select author, body from public.mod_notes where user_id = $1`, [zed]);
  h.eq('test: note left on the new account', [zNote?.author ?? null, /^Name check: took @bob, .*site-banned for good: raiding the HQ.*Old account id/.test(zNote?.body ?? '')], [null, true]);
  h.eq('test: outsider renames into a held name', await rename(erin, 'carl'), 'ok');
  h.eq('test: outsider gets a note', (await h.one(`select count(*)::int n from public.mod_notes where user_id = $1 and body like 'Name check: took @carl,%'`, [erin])).n, 1);
  h.eq('test: tester is refused', await rename(antic, 'fred'), 'That username is taken');

  // everyone: refused for sign-up form and renames, handle_new_user skips the name.
  await h.db.exec(`update public.feature_flags set mode = 'everyone' where key = 'deleted_name_hold'`);
  h.eq('everyone: sign-up form says fred is taken', (await h.one(`select public.srv_username_taken('Fred') v`)).v, true);
  h.eq('everyone: unheld names still free', (await h.one(`select public.srv_username_taken('nobody_here') v`)).v, false);
  const yan = await mk(null, 'yan@example.com', 'fred');
  h.eq('everyone: new account gets fred1', (await h.one(`select username from public.profiles where id = $1`, [yan])).username, 'fred1');
  h.eq('everyone: note says what they tried', /^Name check: tried to take @fred, .* They got @fred1 instead\.$/.test((await h.one(`select body from public.mod_notes where user_id = $1`, [yan]))?.body ?? ''), true);
  h.eq('everyone: rename refused', await rename(dana, 'fred'), 'That username is taken');
  h.eq('everyone: case-only change of your own name is fine', await rename(dana, 'Dana'), 'ok');
  await h.db.exec(`select set_config('test.staff', 'on', false)`);
  h.eq('everyone: staff go through', await rename(dana, 'fred'), 'ok');
  await h.db.exec(`select set_config('test.staff', '', false)`);

  // off: nothing recorded.
  await h.db.exec(`update public.feature_flags set mode = 'off' where key = 'deleted_name_hold'`);
  const hal = await mk(null, 'hal@example.com', 'hal');
  await h.db.query(`insert into public.site_bans (user_id, reason) values ($1, 'x')`, [hal]);
  await h.db.query(`select public.keep_ban_leftovers($1)`, [hal]);
  h.eq('off: nothing held', (await h.one(`select count(*)::int n from public.deleted_name_holds where name_key = 'hal'`)).n, 0);
  h.eq('off: ban leftovers still kept as before', (await h.one(`select count(*)::int n from public.ban_leftovers where email_hash = md5('hal@example.com')`)).n, 1);
  h.eq('off: sign-up form ignores holds', (await h.one(`select public.srv_username_taken('carl1') v`)).v, false);

  // A broken hold never blocks the delete.
  await h.db.exec(`update public.feature_flags set mode = 'test' where key = 'deleted_name_hold'`);
  await h.db.exec(`alter table public.user_warnings rename to user_warnings_gone`);
  await h.ok('keep_ban_leftovers survives a failing hold', () => h.db.query(`select public.keep_ban_leftovers($1)`, [hal]));
  await h.db.exec(`alter table public.user_warnings_gone rename to user_warnings`);
}
