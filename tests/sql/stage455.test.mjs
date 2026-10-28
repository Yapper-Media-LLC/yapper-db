// 455: the 430 word filter, applied again (same checks as stage430).
// Live had lost the 430 bodies; this stage proves the re-apply file carries them.
// Live pieces are stand-ins (unaccent, fold_fancy, six_nine_g, has_slur, create_poll). Slurs are built from pieces.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '455_filter_reapply.sql'), 'utf8');

const STANDINS = String.raw`
set check_function_bodies = off;
create schema if not exists extensions;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$ select t $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
create or replace function public.has_slur(t text) returns boolean language sql immutable as $$ select public.has_slur_plain(t) $$;
create or replace function public.create_poll(cid uuid, question text, opts text[], multi boolean DEFAULT false, hours integer DEFAULT 24)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare o jsonb := '[]'::jsonb; i int;
begin
  for i in 1 .. array_length(opts, 1) loop
    o := o || jsonb_build_object('id', i::text, 'text', trim(opts[i]));
  end loop;
  return o;
end;
$function$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('455 re-runs cleanly', () => h.db.exec(MIG));
  const def = (await h.one(`select pg_get_functiondef('public.create_poll(uuid,text,text[],boolean,integer)'::regprocedure) d`)).d;
  h.eq('create_poll patched once', def.split('-- 430: options are checked').length - 1, 1);

  const n = 'n', i = 'i', gg = 'gg', G = 'GG';
  const slurs = [`${n}${i}ᵹᵹa`, `N§${G}A`, `${n}§${gg}a`, `${n}ii${'g'}err`, `${n}${i}${'g'}err`, 'NIGR', `hey ${n}${i}grs`, `${n}ɨ${gg}a`, `${n}${i}ɠɠa`];
  for (const t of slurs) h.eq(`blocks look-alike #${slurs.indexOf(t)}`, (await h.one(`select has_slur($1) v`, [t])).v, true);
  const fine = ['Niger', 'Nigeria is big', 'nigiri sushi', 'NIGHT shift', 'Nigel', 'section § 4', '~hello~', 'x^2 + y^2', 'nice • list', '¿que?', 'snack', 'bigger', 'trigger'];
  for (const t of fine) h.eq(`allows "${t}"`, (await h.one(`select has_slur($1) v`, [t])).v, false);

  const k = 'k';
  const harm = [`${k}iii yourself`, `${k}iII yourself`, `${k}lll ur self`, `${k}il yourself`, `${k}ill yo self`, `${k}ill ya self`, `${k}ill yourselves`, `${k}*ll yourself`, `${k}.i.l.l yourself`, `go ${k}ill yourself`, `${k}ill your self`, 'kys'];
  for (const t of harm) h.eq(`self-harm "${t}"`, (await h.one(`select has_self_harm_incitement($1) v`, [t])).v, true);
  const ok = ['skill yourself up', 'kill the boss', 'I killed it', 'kiss yourself goodbye', 'fill yourself in', 'build your self esteem', 'killer queen', 'kiln yourself', 'skills', 'u good?'];
  for (const t of ok) h.eq(`allows "${t}"`, (await h.one(`select has_self_harm_incitement($1) v`, [t])).v, false);

  await h.fails('poll option with a slur', `select create_poll(gen_random_uuid(), 'q', array['ok', '${n}ii${'g'}err'])`);
  await h.fails('poll option telling someone to die', `select create_poll(gen_random_uuid(), 'q', array['${k}iii yourself', 'no'])`);
  h.eq('normal poll goes through', (await h.one(`select jsonb_array_length(create_poll(gen_random_uuid(), 'pizza?', array['yes', 'no'])) v`)).v, 2);
}
