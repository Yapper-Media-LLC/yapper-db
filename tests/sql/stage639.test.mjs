// 639: decoration uploads open again for the test group (flag deco_uploads_open) while deco_submissions_closed stays on.
// Stand-ins carry the 535 line of submit_community_deco that 639 patches in place, and a tiny feature_flags table.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '639_deco_uploads_reopen.sql'), 'utf8');

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`639 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(String.raw`
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.flag_on (key text primary key);
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$ select exists (select 1 from public.flag_on where key = k) $$;
create or replace function public.submit_community_deco(p_name text, p_path text, p_event text DEFAULT NULL::text)
 returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare me uuid := (select auth.uid());
begin
  if me is null then raise exception 'Sign in first'; end if;
  if public.feature_on_for_me('deco_submissions_closed') then raise exception 'Decoration submissions are paused for now'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper.'; end if;
  return gen_random_uuid();
end; $function$;
`);
  await h.ok('639 runs', () => h.db.exec(MIG));
  await h.ok('639 re-runs cleanly', () => h.db.exec(MIG));
  const def = (await h.one(`select pg_get_functiondef('public.submit_community_deco(text,text,text)'::regprocedure) d`)).d;
  h.eq('open check patched in once', def.split('deco_uploads_open').length - 1, 1);
  h.eq('closed check still there once', def.split('deco_submissions_closed').length - 1, 1);
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'deco_uploads_open'`);
  h.eq('flag in test mode', flag.mode, 'test');
  h.eq('flag on the HQ test server', flag.servers.includes('00000000-0000-4000-8000-00000000b001'), true);
  h.eq('flag on for Antic', flag.users.includes('00000000-0000-4000-8000-00000000a001'), true);

  const member = await h.signup('m@x.com', 'member');
  await h.as(member);
  await h.ok('submission goes through while nothing is on', () => h.q(`select submit_community_deco('Name', 'p/x.png')`));
  await h.admin();
  await h.q(`insert into flag_on values ('deco_submissions_closed')`);
  await h.as(member);
  await h.fails('refused while paused and not in the test group', `select submit_community_deco('Name', 'p/x.png')`);
  await h.fails('event submission refused too', `select submit_community_deco('Name', 'p/x.png', 'halloween_2026')`);
  await h.admin();
  await h.q(`insert into flag_on values ('deco_uploads_open')`);
  await h.as(member);
  await h.ok('goes through for the test group while paused', () => h.q(`select submit_community_deco('Name', 'p/x.png')`));
  await h.ok('event submission too', () => h.q(`select submit_community_deco('Name', 'p/x.png', 'halloween_2026')`));
}
