// 270: Supercharge fixes after launch. Stand-ins for the tables/helpers 270 runs next to (PGlite stops at 024), 264 on
// top, and short versions of the live functions 270 patches in place (same anchor lines). Then 270 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const STANDINS = `
create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.servers add column if not exists banner_path text;
alter table public.servers add column if not exists banner_x numeric default 50;
alter table public.servers add column if not exists banner_y numeric default 50;
alter table public.servers add column if not exists banner_zoom numeric default 1;
alter table public.servers add column if not exists icon_path text;
alter table public.invites add column if not exists vanity boolean not null default false;
create table if not exists public.vanity_changes (server_id uuid, user_id uuid, at timestamptz not null default now());
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (user_id uuid primary key);
create table if not exists public.site_admins (user_id uuid primary key);
create table if not exists public.media_scans (bucket text, path text, user_id uuid, score real, verdict text, primary key (bucket, path));
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select false $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) $$;
create or replace function public.media_ok(b text, p text) returns boolean language sql stable as $$ select true $$;
create or replace function public.check_icon_path(p text) returns void language sql as $$ select $$;
create or replace function public.lookalike_key(t text) returns text language sql immutable as $$ select lower(t) $$;
create or replace function public.vanity_key(t text) returns text language sql immutable as $$ select lower(t) $$;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.brand_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.vanity_reserved(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.fix_role_pings(sid uuid, cid uuid, cp boolean, t text) returns text language sql as $$ select t $$;
`;
const LIVE_SHAPES = `
CREATE OR REPLACE FUNCTION public.create_server(server_name text, server_icon text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare sid uuid;
begin
  perform public.check_icon_path(server_icon);
  insert into public.servers (name, icon_path, owner_id) values (btrim(server_name), server_icon, auth.uid()) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, auth.uid());
  return sid;
end; $function$;
CREATE OR REPLACE FUNCTION public.create_server_from_template(tcode text, server_name text, server_icon text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare sid uuid;
begin
  perform public.check_icon_path(server_icon);
  insert into public.servers (name, icon_path, owner_id) values (btrim(server_name), server_icon, auth.uid()) returning id into sid;
  return sid;
end; $function$;
CREATE OR REPLACE FUNCTION public.message_perm_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare sid uuid; cp boolean := false;
begin
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then new.content := public.fix_role_pings(null, new.channel_id, false, new.content); return new; end if;
  new.content := public.fix_role_pings(sid, new.channel_id, cp, new.content);
  return new;
end; $function$;
create trigger messages_perm_guard_t before insert on public.messages for each row execute function public.message_perm_guard();
`;

export default async function (h) {
  const failsWith = async (name, re, sql, params = []) => {
    let msg = null;
    try { await h.db.query(sql, params); } catch (e) { msg = e.message; }
    h.eq(name, msg !== null && re.test(msg) ? 'refused' : msg, 'refused');
  };
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('264_supercharge.sql'));
  await h.db.exec(LIVE_SHAPES);
  const MIG = mig('270_supercharge_fixes.sql');
  await h.db.exec(MIG);
  await h.ok('270 re-runs cleanly', () => h.db.exec(MIG));
  await h.q(`update feature_flags set mode = 'everyone' where key = 'supercharge'`);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, amy, bob]);
  const other = (await h.one(`insert into servers (name, owner_id) values ('O', $1) returning id`, [bob])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [other, amy, bob]);
  const chan = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  const otherChan = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [other, bob])).id;
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', 'k1', $1) returning id`, [amy])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, amy, bob]);
  await h.q(`insert into media_scans (bucket, path, user_id, verdict, animated) values
    ('icons', $1, $2, 'ok', true), ('icons', $3, $2, 'ok', false), ('banners', $4, $2, 'ok', false),
    ('attachments', $5, $2, 'ok', null), ('attachments', $6, $2, 'ok', null)`,
    [`${amy}/a.webp`, amy, `${amy}/s.webp`, `${amy}/b.png`, `${amy}/big.mp4`, `${amy}/small.png`]);
  await h.q(`update media_scans set for_server = $1 where path = $2`, [sid, `${amy}/big.mp4`]);

  await h.as(amy);
  // 1. Banners are free again.
  await h.ok('a new banner at level 0 works again', () => h.q(`select set_server_banner($1, $2, 50, 50, 1)`, [sid, `${amy}/b.png`]));
  // 2. Animated icons.
  await failsWith('animated WebP icon at level 0 refused', /Animated icons unlock/, `select update_server($1, 'S', $2)`, [sid, `${amy}/a.webp`]);
  await failsWith('GIF icon at level 0 still refused', /Animated icons unlock/, `select update_server($1, 'S', $2)`, [sid, `${amy}/x.gif`]);
  await h.ok('still WebP icon is fine', () => h.q(`select update_server($1, 'S', $2)`, [sid, `${amy}/s.webp`]));
  await failsWith('new server with an animated icon refused', /Pick a still picture/, `select create_server('New', $1)`, [`${amy}/a.webp`]);
  await failsWith('new server from a template with a GIF refused', /Pick a still picture/, `select create_server_from_template('abc', 'New', $1)`, [`${amy}/x.gif`]);
  await h.ok('new server with a still icon is fine', () => h.q(`select create_server('New', $1)`, [`${amy}/s.webp`]));
  await h.admin();
  await h.q(`update feature_flags set mode = 'test' where key = 'supercharge'`);
  await h.as(amy);
  await h.ok('before launch: new servers could still start animated', () => h.q(`select create_server('New2', $1)`, [`${amy}/a.webp`]));
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'supercharge'`);
  await h.q(`insert into supercharges (user_id, server_id, source, until, applied_at, last_server_id) select $1, $2, 'admin', now() + interval '30 days', now(), $2 from generate_series(1, 2)`, [amy, sid]);
  await h.as(amy);
  await h.ok('level 1: animated icon allowed', () => h.q(`select update_server($1, 'S', $2)`, [sid, `${amy}/a.webp`]));

  // 3. Big files stay in the server they were allowed for.
  const send = (cid, path) => h.q(`insert into messages (channel_id, author_id, content, attachment_path) values ($1, auth.uid(), '', $2)`, [cid, path]);
  await h.ok('big file in its server', () => send(chan, `${amy}/big.mp4`));
  await failsWith('big file in a DM refused', /only be sent in the supercharged server/, `insert into messages (channel_id, author_id, content, attachment_path) values ($1, auth.uid(), '', $2)`, [dm, `${amy}/big.mp4`]);
  await failsWith('big file in another server refused', /only be sent in the supercharged server/, `insert into messages (channel_id, author_id, content, attachment_path) values ($1, auth.uid(), '', $2)`, [otherChan, `${amy}/big.mp4`]);
  await h.ok('normal file in a DM is fine', () => send(dm, `${amy}/small.png`));
  await h.ok('normal file in another server is fine', () => send(otherChan, `${amy}/small.png`));
}
