// 273 slur filter hardening. PGlite can't replay migrations 025+, so this starts from stage 24 and adds stand-ins for
// the live pieces 273 builds on: unaccent, fold_fancy, the slur_text that 146 patched, and profiles.custom_status.
// The words are put together from pieces so this file doesn't spell the worst ones out.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export const base = 24;

const STANDINS = String.raw`
create schema if not exists extensions;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$ select t $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
create or replace function public.slur_text(t text) returns text language sql immutable set search_path to 'public', 'extensions' as $function$
  select regexp_replace(
    regexp_replace(
      translate(lower(unaccent(regexp_replace(public.fold_fancy(t), '[​-‏]', '', 'g'))), '0134578@$!|', 'oieastbasii'),
      '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g');
$function$;
alter table public.profiles add column if not exists custom_status text;
`;

// fold_fancy stand-in that does the two things 273 relies on: drops hidden characters and turns fullwidth 6 / 9 into plain ones.
const C = (...n) => n.map((c) => String.fromCharCode(c)).join('');
const FOLD = `create or replace function public.fold_fancy(t text) returns text language sql immutable as $$
  select translate(regexp_replace(coalesce(t, ''), '[${C(0x200b)}-${C(0x200f)}${C(0xad, 0x2060, 0xfeff)}]', '', 'g'), '${C(0xff16, 0xff19)}', '69') $$;`;

const BIDI = { rlo: String.fromCharCode(0x202e), rle: String.fromCharCode(0x202b), pdf: String.fromCharCode(0x202c), rli: String.fromCharCode(0x2067), pdi: String.fromCharCode(0x2069) };
const rev = (s) => [...s].reverse().join('');
const HEBREW = String.fromCharCode(0x5e9, 0x5dc, 0x5d5, 0x5dd);

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(FOLD);
  const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '273_slur_filter_hardening.sql'), 'utf8');
  const nword = (mid, end) => ['n', 'i', mid, end].join('');
  const has = async (t) => (await h.one(`select has_slur($1) r`, [t])).r;
  const expectAll = async (label, list, want) => {
    for (const t of list) h.eq(`${label}: ${JSON.stringify(t)}`, await has(t), want);
  };

  // What the old filter said, so "can only get stricter" is checked against the real thing: whatever it refused is
  // still refused, and slur_text (shared with names, spam and the auto-ban) is untouched.
  const slurTextBefore = (await h.one(`select pg_get_functiondef('public.slur_text(text)'::regprocedure) d`)).d;
  const oldRefused = ['n6igger', 'nigge6r', nword('g', 'ger'), 'x' + nword('g', 'ger') + 'x', 'retard9x', 'ni69gger', 'f9aggot', 'xniggerx'];
  const oldAnswers = [];
  for (const t of oldRefused) oldAnswers.push((await h.one(`select has_slur($1) r`, [t])).r);
  const before = {
    digits: (await h.one(`select has_slur($1) r`, [nword('99', 'er')])).r,
    masked: (await h.one(`select has_slur($1) r`, ['re*tard'])).r,
  };
  h.eq('before 273 the digit and symbol tricks got through', before, { digits: false, masked: false });

  await h.db.exec(MIGRATION);
  await h.ok('273 re-runs cleanly', () => h.db.exec(MIGRATION));
  h.eq('slur_text is left alone (names, spam and the auto-ban use it)', (await h.one(`select pg_get_functiondef('public.slur_text(text)'::regprocedure) d`)).d, slurTextBefore);
  for (const [i, t] of oldRefused.entries()) h.eq(`still refused if it was before: ${JSON.stringify(t)}`, !oldAnswers[i] || (await has(t)), true);
  await expectAll('the digit-next-to-a-letter spellings', oldRefused, true);

  // Caught now.
  await expectAll('digits in the middle of a word', [nword('99', 'er'), nword('66', 'a'), nword('69', 'a'), nword('9669', 'er'), nword('6', 'ga'), nword('6666666', 'er'), nword('g', '9er')], true);
  await expectAll('symbols inside a word', ['re*tard', 'r*tard', 'k*ike', 'chi.nk', 'ch*nk', 'tr*nny', 'r.e.t.a.r.d'], true);
  await expectAll('written backwards with a right-to-left override', [BIDI.rlo + rev('retard'), BIDI.rlo + rev(nword('g', 'ger')), 'hello ' + BIDI.rlo + rev('retard') + BIDI.pdf], true);
  // Hidden characters and fullwidth digits next to the 6 or 9, ids glued to a word, a word written backwards with digits in it.
  const fword = ['fa', '99', 'ot'].join('');
  await expectAll('hidden characters and fullwidth digits next to the 6 or 9', [
    ['ni9', C(0x200b), '9er'].join(''), ['ni99', C(0x200b), 'er'].join(''), ['ni9', C(0xad), '9er'].join(''),
    nword(C(0xff16, 0xff16), 'a'), nword(C(0xff16) + '6', 'er'),
  ], true);
  await expectAll('a run of hex glued to a word is not an id', [
    '0123456789abcdef0123' + fword, '00000000-0000-0000-0000-00000000' + fword, nword('6'.repeat(20), 'er'),
  ], true);
  await expectAll('backwards with digits in it', [BIDI.rlo + rev(nword('99', 'er')), BIDI.rlo + rev(fword), BIDI.rlo + rev(nword('66', 'a'))], true);
  // Not hidden by something that looks like a mention.
  await expectAll('inside brackets', [`<@${nword('99', 'er')}>`, `<:${nword('66', 'a')}:x>`], true);

  // Still fine. Years and ids are the ones that go wrong when digits are read as letters.
  await expectAll('years and numbers', [
    'in 1969 a man walked on the beach', 'in 1996 era', 'in 1966 era of the', 'it was in 1999 and a long time',
    'we scored 96 points a game', 'win 9 games a year', 'night 9 knights', 'round 6 gamers', 'John 3:16 and Psalm 69 verse 9',
  ], false);
  // Ids that would read as a slur once their 6s and 9s turn into g: letters fa, 99, e7.
  const hash = 'a1b2c3d4e5'.repeat(3) + 'fa99e7' + 'c0ffee'.repeat(5);
  await expectAll('ids inside mentions, custom emojis, links and bare hashes', [
    'hi <@00000000-0000-4000-8000-00000000a008> welcome', '<:autism_moment:cf02fa66-bf8c-4215-b182-8e771b684060>',
    '<a:awkward:1558873f-faa9-4af7-a281-a6d3b38a6f6e> <:download:0affc41c-2fa9-4835-8139-9792ecf41c3c>',
    'hi <@161e551e-fa99-e7aa-908b-719b982fa620> welcome', '<:x_y:0affc41c-fa66-e7aa-9139-8c4121c0cf4d>', 'hi <@&161e551e-fa99-e7ab-908b-719b982fa620>',
    `https://cdn.yapper.website/files/${hash}.png`, `sha ${hash}`,
  ], false);
  const edge = `'(?<=[[:alpha:]])[69](?=[69]*[[:alpha:]])'`;
  h.eq('the id cases are a real trap: with 6 and 9 read as g and nothing blanked, fa99e7 is a slur',
    (await h.one(`select has_slur_plain(regexp_replace(regexp_replace('fa99e7', ${edge}, 'g', 'g'), ${edge}, 'g', 'g')) r`)).r, true);
  await expectAll('ordinary text with symbols', [
    'hello world, how are you?', 'the end... of an era. wow!! what a day?', 'a.k.a. spice and S.P.I.C.E.', 'see https://example.com/a_b-c?x=1&y=2',
  ], false);
  // Only the override reverses letters. Embeddings and isolates keep Latin text going forwards, so these are just text.
  await expectAll('right-to-left text, embeddings and isolates', [
    BIDI.rle + HEBREW + BIDI.pdf, BIDI.rlo + 'hello there', BIDI.rle + HEBREW + ' dragging and tagging the nagging gin ' + BIDI.pdf,
    BIDI.rli + HEBREW + ' dragging ' + BIDI.pdi, BIDI.rle + rev('retard') + BIDI.pdf, BIDI.rli + rev('retard') + BIDI.pdi,
  ], false);

  // Same callers as has_slur, nobody else.
  const canRun = async (role, fn) => (await h.one(`select has_function_privilege($1, $2, 'execute') r`, [role, fn])).r;
  for (const fn of ['public.has_slur_plain(text)', 'public.six_nine_g(text)']) {
    h.eq(`${fn} runs for signed-in users and the service`, [await canRun('authenticated', fn), await canRun('service_role', fn)], [true, true]);
    h.eq(`${fn} does not run for anon`, await canRun('anon', fn), false);
  }

  // A custom status is checked like a bio.
  const amy = await h.signup('amy273@example.com', 'amy273');
  await h.admin();
  await h.ok('a normal status is fine', () => h.q(`update profiles set custom_status = 'studying for exams' where id = $1`, [amy]));
  await h.ok('clearing a status is fine', () => h.q(`update profiles set custom_status = null where id = $1`, [amy]));
  await h.fails('a status with a masked slur is refused', `update profiles set custom_status = $2 where id = $1`, [amy, 're*tard']);
  await h.fails('a status with a digit slur is refused', `update profiles set custom_status = $2 where id = $1`, [amy, nword('99', 'er')]);
  // Only when the status itself changes: other profile edits don't re-check an old one.
  await h.db.exec(`alter table profiles disable trigger profiles_status_no_slurs`);
  await h.q(`update profiles set custom_status = 're*tard' where id = $1`, [amy]);
  await h.db.exec(`alter table profiles enable trigger profiles_status_no_slurs`);
  await h.ok('editing the bio leaves an old status alone', () => h.q(`update profiles set bio = 'hello' where id = $1`, [amy]));
}
