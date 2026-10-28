// 390: word filter look-alike fixes (lowercase l for I in caps, vowel-dropped f-slur as a whole word).
// Same stand-ins as stage 325 for the live pieces (unaccent, fold_fancy, slur_text, six_nine_g). Slurs are built from pieces.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '390_bug_fixes_1022.sql'), 'utf8');

const STANDINS = String.raw`
set check_function_bodies = off;
create schema if not exists extensions;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$ select t $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
create or replace function public.six_nine_g(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
create or replace function public.slur_text(t text) returns text language sql immutable set search_path to 'public', 'extensions' as $function$
  select regexp_replace(
    regexp_replace(
      translate(lower(unaccent(regexp_replace(public.fold_fancy(t), '[​-‏]', '', 'g'))), '0134578@$!|', 'oieastbasii'),
      '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g');
$function$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('390 re-runs cleanly', () => h.db.exec(MIG));
  const N = 'N', G = 'GG', g = 'gg', F = 'f';
  const blocked = [`${N}l${G}A`, `${N}l${G}ER`, `hey ${N}l${G}A lol`, `Nl${g}a`, `${F}got`, `${F}ggot`, `you ${F}gots`, `${F} g o t`, `${N}I${G}A`];
  for (const t of blocked) h.eq(`blocks ${t.length}-char look-alike #${blocked.indexOf(t)}`, (await h.one(`select has_slur($1) v`, [t])).v, true);
  const fine = ['HELLO', 'ALL CAPS Nl', 'ufgotit', 'NlGHT shift', 'BlOG', 'I forgot', 'Nlrn', 'fg', 'ALlGN', 'only lowercase l here', 'use fgets() to read a line', 'CAlGARY', 'HTML lGBT'];
  for (const t of fine) h.eq(`allows "${t}"`, (await h.one(`select has_slur($1) v`, [t])).v, false);
}
