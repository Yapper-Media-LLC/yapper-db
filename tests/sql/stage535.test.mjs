// 535: word filter gaps from the Oct 26 bug queue (spaced letters with an l for the i, a split r-slur, more ways to
// say "kill yourself") and a cap of 5 normal invite links per person per server.
// Starts from stage 24 with the 455 filter bodies; unaccent, fold_fancy, six_nine_g, server_perm and is_staff_user are
// stand-ins. Slurs are built from pieces.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('535_bug_queue_filter_invites.sql');

const STANDINS = String.raw`
set check_function_bodies = off;
create schema if not exists extensions;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$ select t $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
create or replace function public.six_nine_g(t text) returns text language sql immutable as $$ select translate(coalesce(t, ''), '69', 'gg') $$;
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
alter table public.invites add column if not exists vanity boolean not null default false;
create table if not exists public.staff_ids (id uuid primary key);
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.staff_ids where id = uid) $$;
alter table public.roles add column if not exists perms jsonb not null default '{}';
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid() and coalesce((r.perms ->> perm)::boolean, false));
$$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`535 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('455_filter_reapply.sql'));
  // Stand-ins carrying the live anchor lines of the two functions 535 patches in place.
  await h.db.exec(String.raw`
create table if not exists public.flag_on (key text primary key);
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$ select exists (select 1 from public.flag_on where key = k) $$;

create or replace function public.is_site_admin() returns boolean language sql stable as $$ select false $$;
create or replace function public.submit_community_deco(p_name text, p_path text, p_event text DEFAULT NULL::text)
 returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare me uuid := (select auth.uid());
begin
  if me is null then raise exception 'Sign in first'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper.'; end if;
  return gen_random_uuid();
end; $function$;
create or replace function public.staff_decide_appeal(aid uuid, approve boolean)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare a record; known boolean := false; can_allow boolean := false;
begin
  select 'avatars'::text bucket, 'x'::text sha256 into a;
  if aid is null then select 'attachments'::text bucket, 'x'::text sha256 into a; end if;
  if public.is_site_admin() and not known and a.sha256 is not null then
    can_allow := true;
  end if;
  return jsonb_build_object('allowed', can_allow);
end; $function$;
`);
  await h.ok('535 runs', () => h.db.exec(MIG));
  await h.ok('535 re-runs cleanly', () => h.db.exec(MIG));

  const n = 'n', l = 'l', gg = 'g g', G = 'G G', r = 're';
  const slurs = [`${n} ${l} ${gg} e r`, `N ${l} ${G} E R`, `${n} ${l} ${gg} a`, `you ${r} tard`, `${r} tarded`, `${n}${l}gger`, `N${l}GGA`, `a ${n} ${l} ${gg} e r`];
  for (const t of slurs) h.eq(`blocks "${t.replace(/[aeiou]/g, '*')}"`, (await h.one(`select has_slur($1) v`, [t])).v, true);
  const fine = ['Niger', 'Nigeria is big', 'nigiri sushi', 'NIGHT shift', 'Nigel', 'bigger', 'trigger', 'I need to re start', 're tarp the roof', 'the tardis', 'only', 'n l p', 'NLP group', 'a re t'];
  for (const t of fine) h.eq(`allows "${t}"`, (await h.one(`select has_slur($1) v`, [t])).v, false);

  const k = 'k';
  const harm = [`${k}ill ys`, `${k}*ll ys`, `${k}ill thy self`, `${k}*ll thy self`, `${k}ill thyself`, `suicide yourself`, `s*icide yourself`, `${k}ill yourself`, 'kys'];
  for (const t of harm) h.eq(`self-harm "${t}"`, (await h.one(`select has_self_harm_incitement($1) v`, [t])).v, true);
  const ok = ['skill yourself up', 'kill the boss', 'I killed it', 'killer queen', 'skills', 'kill ya later', 'the suicide squad movie', 'thy will be done', 'kill yesterday', 'build your self esteem', "i'll kill urs", 'my build will kill urs', 'kill yrs off your life'];
  for (const t of ok) h.eq(`allows "${t}"`, (await h.one(`select has_self_harm_incitement($1) v`, [t])).v, false);

  // Invites: 5 normal links per person per server.
  const owner = await h.signup('o@x.com', 'owner');
  const member = await h.signup('m@x.com', 'member');
  const mgr = await h.signup('g@x.com', 'manager');
  const staff = await h.signup('s@x.com', 'staffer');
  await h.admin();
  await h.q(`insert into staff_ids values ($1)`, [staff]);
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  const T = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner])).id;
  for (const s of [S, T]) for (const u of [owner, member, mgr, staff]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [s, u]);
  const role = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Mods', 1, '{"manage_server": true}'::jsonb) returning id`, [S])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, mgr, role]);

  let seq = 0;
  const code = () => `Code${String(++seq).padStart(6, '0')}`;
  const add = (by, sid) => h.q(`insert into invites (code, server_id, created_by) values ($1, $2, $3)`, [code(), sid, by]);

  await h.as(member);
  for (let i = 1; i <= 5; i++) await h.ok(`member link ${i} of 5`, () => add(member, S));
  await h.fails('member 6th link refused', `insert into invites (code, server_id, created_by) values ('Code999999', $1, $2)`, [S, member]);
  await h.ok('member can still make one for another server', () => add(member, T));
  await h.admin();
  h.eq('member holds 5 in S', (await h.one(`select count(*)::int c from invites where server_id = $1 and created_by = $2`, [S, member])).c, 5);
  await h.q(`insert into invites (code, server_id, created_by, vanity) values ('Vanity0001', $1, $2, true)`, [T, member]);

  await h.as(mgr);
  for (let i = 1; i <= 7; i++) await h.ok(`manager link ${i} (no cap)`, () => add(mgr, S));
  await h.as(owner);
  for (let i = 1; i <= 6; i++) await h.ok(`owner link ${i} (no cap)`, () => add(owner, S));
  await h.as(staff);
  for (let i = 1; i <= 6; i++) await h.ok(`staff link ${i} (no cap)`, () => add(staff, T));

  await h.admin();
  for (let i = 1; i <= 6; i++) await h.ok(`no session (service role) link ${i}`, () => add(member, S));
  await h.as(member);
  await h.fails('still refused for the member afterwards', `insert into invites (code, server_id, created_by) values ('Code888888', $1, $2)`, [S, member]);

  // Decoration submissions refused while deco_submissions_closed is on (also for the Halloween event).
  await h.as(member);
  await h.ok('submission goes through while open', () => h.q(`select submit_community_deco('Name', 'p/x.png', 'halloween_2026')`));
  await h.admin();
  await h.q(`insert into flag_on values ('deco_submissions_closed')`);
  await h.as(member);
  await h.fails('submission refused while closed', `select submit_community_deco('Name', 'p/x.png', 'halloween_2026')`);
  await h.fails('normal submission refused while closed', `select submit_community_deco('Name', 'p/x.png')`);

  // Upload reviews: a non-admin approve allow-lists avatars and banners only.
  h.eq('mod approve of an avatar goes on the allow list', (await h.one(`select (staff_decide_appeal(gen_random_uuid(), true) ->> 'allowed')::boolean v`)).v, true);
  h.eq('mod approve of a chat file stays admin only', (await h.one(`select (staff_decide_appeal(null, true) ->> 'allowed')::boolean v`)).v, false);
  await h.admin();
  await h.ok('patches re-run cleanly', () => h.db.exec(MIG));
  const def = (await h.one(`select pg_get_functiondef('public.submit_community_deco(text,text,text)'::regprocedure) d`)).d;
  h.eq('closed check patched in once', def.split('deco_submissions_closed').length - 1, 1);

  h.eq('trigger function not callable by app users',
    (await h.one(`select has_function_privilege('authenticated', 'public.invites_per_person_cap()', 'execute') v`)).v, false);
}
