// 658: set_server_lobby_v2 keeps an optional boolean `side` on each section (which column a block sits in, flag
// lobby_sections_ux). Left out stays left out; anything not a boolean is dropped; everything else as in 615.
// Starts from stage 24 with the 615 stand-ins.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('658_lobby_section_side.sql');
const sorted = (v) => Array.isArray(v) ? v.map(sorted) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])])) : v;

const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists ticket_by uuid;
alter table public.channels add column if not exists private boolean not null default false;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create or replace function public.has_slur(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badword%' $$;
create or replace function public.has_sexual_spam(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%spamword%' $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badsite.com%' $$;
create table if not exists public.audit_seen (sid uuid, act text, actor uuid, extra jsonb);
create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
 returns void language sql security definer set search_path = public as $$ insert into public.audit_seen values (sid, act, auth.uid(), extra) $$;
create table if not exists public.server_bots (server_id uuid, bot text, enabled boolean, config jsonb default '{}');
create table if not exists public.server_xp (server_id uuid, user_id uuid, xp int, level int, last_at timestamptz default now(), primary key (server_id, user_id));
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.servers add column if not exists shut_down_at timestamptz;
create or replace function public.is_staff() returns boolean language sql stable as $$ select false $$;
create table if not exists public.giveaways (id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid, message_id uuid,
  host_id uuid, prize text, winners int default 1, ends_at timestamptz, ended_at timestamptz, winner_ids uuid[], plus_months int);
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`658 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('533_server_lobby.sql'));
  await h.db.exec(mig('602_lobby_v2.sql'));
  await h.db.exec(mig('615_lobby_on_extras.sql'));
  await h.ok('658 runs', () => h.db.exec(MIG));
  await h.ok('658 re-runs cleanly', () => h.db.exec(MIG));

  const owner = await h.signup('o@x.com', 'owner');
  const member = await h.signup('p@x.com', 'plain');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  for (const u of [owner, member]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  await h.q(`update feature_flags set servers = array_append(servers, $1) where key in ('lobby_v2', 'server_lobby')`, [S]);

  const call = `select public.set_server_lobby_v2($1, 'Hi', '[]'::jsonb, '{}'::uuid[], true, '{}'::jsonb, $2::jsonb)`;
  const row = async () => { await h.admin(); return (await h.one(`select sections from server_lobby where server_id = $1`, [S])).sections; };

  await h.as(owner);
  await h.ok('save with side picks', () => h.q(call, [S, JSON.stringify([
    { id: 'rules', on: true, side: false }, { id: 'about', on: true, side: true }, { id: 'faq', on: true },
    { id: 'links', on: false, side: 'yes' }, { id: 'live', on: true, side: null, junk: 1 }, { id: 'about', on: false, side: false },
  ])]));
  h.eq('side kept when boolean, dropped otherwise, repeats skipped', sorted(await row()), [
    { id: 'rules', on: true, side: false }, { id: 'about', on: true, side: true }, { id: 'faq', on: true },
    { id: 'links', on: false }, { id: 'live', on: true },
  ]);
  await h.as(member);
  await h.fails('plain member still refused', call, [S, '[{"id":"about","on":true,"side":true}]']);
  await h.as(owner);
  await h.fails('still refuses unknown sections', call, [S, '[{"id":"ads","on":true,"side":true}]']);
  await h.admin();
  h.eq('anon cannot run it', (await h.one(`select has_function_privilege('anon', 'public.set_server_lobby_v2(uuid, text, jsonb, uuid[], boolean, jsonb, jsonb)', 'execute') as ok`)).ok, false);
}
