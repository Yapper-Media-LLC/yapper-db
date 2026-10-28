// 481: ± × ÷ + ° mask a slur like * and § do (N±GGA), and has_hate no longer reads hex ids or colour codes as 1488.
// Live pieces are stand-ins (unaccent, fold_fancy, has_slur); has_slur_plain and slur_text come from 430.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

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
  await h.db.exec(mig('430_filter_bypasses.sql'));
  const MIG = mig('481_filter_ids_plusminus.sql');
  await h.ok('481 runs', () => h.db.exec(MIG));
  await h.ok('481 re-runs cleanly', () => h.db.exec(MIG));
  const def = (await h.one(`select pg_get_functiondef('public.has_slur_plain(text)'::regprocedure) d`)).d;
  h.eq('both mask classes patched', def.split('¡¿±×÷+°]').length - 1, 2);
  // 482: live unaccent turns ± into "+/-" (the stand-in here doesn't), so "/" is dropped in the masked reading too.
  const MIG482 = mig('482_filter_slash_mask.sql');
  await h.ok('482 runs', () => h.db.exec(MIG482));
  await h.ok('482 re-runs cleanly', () => h.db.exec(MIG482));
  const def482 = (await h.one(`select pg_get_functiondef('public.has_slur_plain(text)'::regprocedure) d`)).d;
  h.eq('482: removal class has "/", trigger class does not', [def482.split('¡¿±×÷+°/]+').length - 1, def482.split('¡¿±×÷+°]').length - 1], [1, 1]);
  h.eq('482: what unaccent makes of N±GGA is blocked', (await h.one(`select has_slur($1) v`, ['N+/-GGA'])).v, true);
  for (const t of ['and/or', 'tcp/ip + udp', '1/2 + 1/4'])
    h.eq(`482: allows "${t}"`, (await h.one(`select has_slur($1) v`, [t])).v, false);

  const G = 'GG', gg = 'gg';
  for (const t of [`N±${G}A`, `n×${gg}a`, `N+${G}A`, `n°${gg}a`, `N§${G}A`]) h.eq(`blocks ${t.length}-char masked`, (await h.one(`select has_slur($1) v`, [t])).v, true);
  for (const t of ['1 ± 2', '5 × 3 = 15', 'c++ is fine', '20°C outside', 'x^2 + y^2', 'Niger', 'snack'])
    h.eq(`allows "${t}"`, (await h.one(`select has_slur($1) v`, [t])).v, false);

  const hate = async (t) => (await h.one(`select has_hate($1) v`, [t])).v;
  h.eq('1488 still blocked', await hate('1488'), true);
  h.eq('14/88 still blocked', await hate('we say 14/88'), true);
  h.eq('14 88 with a hidden char still blocked', await hate('14​88'), true);
  h.eq('word glued 1488 still blocked', await hate('abc1488'), true);
  h.eq('role ping uuid is not 1488', await hate('React for <@&3f2a1488-7c1e-4b2d-9a0e-5d6c7b8a9f01>'), false);
  h.eq('uuid split 14-88 is not 1488', await hate('<:yellow:0b9c8d14-88aa-4bbb-8ccc-0123456789ab>'), false);
  h.eq('colour code is not 1488', await hate('Colour #fa1488'), false);
  h.eq('bare hex run with 1488 still blocked', await hate('1488aaaabbbbccccdddd'), true);
  h.eq('bare uuid-shaped 1488 still blocked', await hate('14881488-1488-1488-1488-148814881488'), true);
  h.eq('prices stay fine', await hate('$1488 total'), false);
}
