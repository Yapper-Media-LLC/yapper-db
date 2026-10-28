// 480: the username hold message no longer says "just let go" (mod resets hold 30 days), and display names lose
// characters that draw several letters wide (﷽, cuneiform). PGlite stops at 24, so the hold guard is a stand-in with
// the two live raise lines (331's text) around a minimal body.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '480_username_hold_text_wide_names.sql'), 'utf8');

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
create table if not exists public.username_holds (name_key text primary key, user_id uuid not null, until timestamptz not null);
create or replace function public.username_holds_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare k_new text := lower(new.username);
begin
  if tg_op = 'INSERT' then
    if exists (select 1 from public.username_holds h where h.name_key = k_new and h.until > now() and h.user_id <> new.id) then
      raise exception 'That username is taken for now: it was just let go and is held until % UTC.',
      (select to_char(max(h.until) at time zone 'UTC', 'YYYY-MM-DD HH24:MI') from public.username_holds h where h.name_key = k_new)
      using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if exists (select 1 from public.username_holds h where h.name_key = k_new and h.until > now() and h.user_id <> new.id) then
    raise exception 'That username is taken for now: it was just let go and is held until % UTC.',
      (select to_char(max(h.until) at time zone 'UTC', 'YYYY-MM-DD HH24:MI') from public.username_holds h where h.name_key = k_new)
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
-- Stand-in for search_people: only the patched branch, with 141's exact lines.
create or replace function public.search_people(q text)
returns table (id uuid) language plpgsql stable security definer set search_path = public as $$
declare
  needle text := ltrim(lower(btrim(coalesce(q, ''))), '@');
  pat text;
  hi text;
begin
  hi := needle || chr(1114111);
  pat := replace(replace(replace(needle, '\\', '\\\\'), '%', '\\%'), '_', '\\_') || '%';
  return query
    (select p.id from public.profiles p
      where char_length(needle) >= 3
        and (lower(p.username) collate "C") >= needle and (lower(p.username) collate "C") < hi
        and lower(p.username) like pat
      order by (lower(p.username) collate "C")
      limit 20);
end $$;
create trigger profiles_username_limit_holds before insert or update of username on public.profiles
  for each row execute function public.username_holds_guard();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const a = await h.signup('a480@test.dev', 'amy480');
  const b = await h.signup('b480@test.dev', 'bob480');

  await h.ok('480 runs', () => h.db.exec(MIG));
  await h.ok('480 re-runs cleanly', () => h.db.exec(MIG));
  const def = (await h.one(`select pg_get_functiondef('public.username_holds_guard()'::regprocedure) d`)).d;
  h.eq('both raise lines patched', def.split('is on hold until').length - 1, 2);
  h.eq('old wording gone', def.includes('just let go'), false);

  // Held for amy (a mod reset would hold it for the mod, same check).
  await h.q(`insert into username_holds values ('yz480', $1, now() + interval '30 days')`, [a]);
  let msg = '';
  try { await h.q(`update profiles set username = 'yz480' where id = $1`, [b]); } catch (e) { msg = e.message; }
  h.eq('held name refused with the new text', /^That username is on hold until \d{4}-\d\d-\d\d \d\d:\d\d UTC, so nobody can take it yet\.$/.test(msg), true);

  const yz = await h.signup('yz480@test.dev', 'yz');
  await h.signup('yzz480@test.dev', 'yzz480');
  h.eq('2 letters find that exact name only', (await h.q(`select id from search_people('yz')`)).map((r) => r.id), [yz]);
  h.eq('2 letters with no exact name find nobody', (await h.q(`select id from search_people('am')`)).length, 0);
  h.eq('3 letters still prefix-match', (await h.q(`select id from search_people('yzz')`)).length, 1);

  await h.q(`update profiles set display_name = $2 where id = $1`, [a, 'Amy \uFDFD\u{12219}']);
  h.eq('wide glyphs dropped', (await h.one(`select display_name from profiles where id = $1`, [a])).display_name, 'Amy');
  await h.q(`update profiles set display_name = $2 where id = $1`, [a, '\uFDFD']);
  h.eq('only wide glyphs -> no display name', (await h.one(`select display_name from profiles where id = $1`, [a])).display_name, null);
  await h.q(`update profiles set display_name = $2 where id = $1`, [a, 'Zoë ✨ 日本']);
  h.eq('normal names untouched', (await h.one(`select display_name from profiles where id = $1`, [a])).display_name, 'Zoë ✨ 日本');
}
