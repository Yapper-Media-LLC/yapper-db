// 298: a site-banned account reads no channel (server channel or DM); an expired ban doesn't count. Base 024 plus
// stand-ins for what the live can_access_channel leans on, then 298 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '298_banned_cant_read.sql'), 'utf8');

export const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;
alter table public.channels add column if not exists category_id uuid;
alter table public.channels add column if not exists ticket_by uuid;
create table if not exists public.feature_flags (key text primary key, label text not null default '', description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create table if not exists public.channel_roles (channel_id uuid, role_id uuid);
create table if not exists public.member_roles (server_id uuid, user_id uuid, role_id uuid);
create or replace function public.is_staff() returns boolean language sql stable as $$ select false $$;
create or replace function public.auto_role_applies(rid uuid, uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.channel_view_base(cid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql stable as $$ select base $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable as $$ select false $$;
alter table public.server_members add column if not exists joined_at timestamptz default now();
alter table public.channel_members add column if not exists joined_at timestamptz default now();
alter table public.roles add column if not exists auto text;
alter table public.roles add column if not exists auto_before timestamptz;
create or replace function public.my_role_pings() returns table(sid uuid, pats text[]) language sql stable as $$ select null::uuid, null::text[] where false $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$ select true $$;
create or replace function public.channel_history_ok(cid uuid) returns boolean language sql stable as $$ select true $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  // my_mentions (298) calls my_visible_server_channels, which wraps visible_server_channels (also 298): stub, run, then the live wrapper.
  await h.db.exec(`create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable as $$ select * from public.channels where false $$;`);
  await h.db.exec(MIG);
  await h.db.exec(`create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable security definer set search_path = public as $$ select * from public.visible_server_channels(null) $$;`);
  await h.ok('298 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, amy, bob]);
  const ch = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [ch, amy]);
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', $2, $1) returning id`, [amy, amy + ':' + bob])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, amy, bob]);

  const reads = async (who) => {
    await h.as(who);
    const r = await h.one(`select can_access_channel($1) srv, can_access_channel($2) dm, (select count(*)::int from messages where channel_id = $1) msgs`, [ch, dm]);
    await h.admin();
    return r;
  };
  h.eq('before the ban bob reads everything', await reads(bob), { srv: true, dm: true, msgs: 1 });
  await h.as(bob);
  h.eq('before the ban: channel list has it', (await h.one(`select count(*)::int n from visible_server_channels(null)`)).n, 1);
  h.eq('before the ban: search finds it', (await h.one(`select count(*)::int n from search_messages_v2('hi')`)).n, 1);
  await h.admin();

  await h.q(`insert into site_bans (user_id, reason, expires_at) values ($1, 'test', now() + interval '1 day')`, [bob]);
  h.eq('banned: no server channel, no DM, no messages', await reads(bob), { srv: false, dm: false, msgs: 0 });
  await h.as(bob);
  h.eq('banned: channel list empty', (await h.one(`select count(*)::int n from visible_server_channels(null)`)).n, 0);
  h.eq('banned: search finds nothing', (await h.one(`select count(*)::int n from search_messages_v2('hi')`)).n, 0);
  h.eq('banned: no mentions', (await h.one(`select count(*)::int n from my_mentions(40)`)).n, 0);
  await h.admin();
  h.eq('other people are untouched', await reads(amy), { srv: true, dm: true, msgs: 1 });

  await h.q(`update site_bans set expires_at = now() - interval '1 minute' where user_id = $1`, [bob]);
  h.eq('expired ban: back to normal', await reads(bob), { srv: true, dm: true, msgs: 1 });
}
