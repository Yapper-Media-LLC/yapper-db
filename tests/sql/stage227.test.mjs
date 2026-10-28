// 227: suggestions form. Only HQ's #suggestions-new takes them (via submit_suggestion), each is posted as the
// person's own message, 3 a day, readable by the author and staff, only staff can change the review fields.
// Runs on stage 24 plus stand-ins for the later bits it touches.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
create table if not exists public.app_settings (id boolean primary key default true);
alter table public.app_settings add column if not exists default_server_id uuid;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[]);
alter table public.channels add column if not exists position int not null default 0;
alter table public.channels add column if not exists read_only boolean not null default false;
alter table public.channels add column if not exists private boolean not null default false;
alter table public.channels add column if not exists slowmode int not null default 0;
alter table public.channels add column if not exists created_by uuid;
create table if not exists public.roles (id uuid primary key default gen_random_uuid(), server_id uuid, name text, position int default 0);
create table if not exists public.channel_roles (channel_id uuid, role_id uuid, server_id uuid, primary key (channel_id, role_id));
create table if not exists public.staff_standin (user_id uuid primary key);
grant select on public.staff_standin to authenticated;
create table if not exists public.ban_standin (user_id uuid primary key);
grant select on public.ban_standin to authenticated;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.ban_standin where user_id = uid) $$;
alter table public.channels add column if not exists category_id uuid;
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create table if not exists public.mute_standin (user_id uuid primary key);
grant select on public.mute_standin to authenticated;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.server_members where server_id = sid and user_id = auth.uid())
           and not (perm = 'send_messages' and exists (select 1 from public.mute_standin where user_id = auth.uid())) $$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql stable as $$ select true $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable
  as $$ select exists (select 1 from public.feature_flags where key = k and (mode = 'everyone' or (mode = 'test' and sid = any(servers)))) $$;
create or replace function public.can_access_channel(cid uuid) returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.channels c join public.server_members m on m.server_id = c.server_id and m.user_id = auth.uid() where c.id = cid) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const owner = await h.signup('o@x.com', 'antic');
  const a = await h.signup('a@x.com', 'idea_guy');
  const b = await h.signup('b@x.com', 'other');
  const staff = await h.signup('s@x.com', 'mod');
  const banned = await h.signup('x@x.com', 'banned');
  await h.admin();
  const hq = (await h.one(`insert into public.servers (name, owner_id) values ('Yapper HQ', $1) returning id`, [owner])).id;
  const other = (await h.one(`insert into public.servers (name, owner_id) values ('Other', $1) returning id`, [b])).id;
  for (const u of [owner, a, staff, banned]) await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [hq, u]);
  await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [other, b]);
  await h.q(`insert into public.app_settings (id, default_server_id) values (true, $1) on conflict (id) do update set default_server_id = excluded.default_server_id`, [hq]);
  await h.q(`insert into public.roles (server_id, name) values ($1, 'Moderator'), ($1, 'Admin'), ($1, 'OG')`, [hq]);
  // Old enough accounts (raid protection holds new ones back in the community server).
  await h.q(`update public.profiles set created_at = now() - interval '2 hours'`);
  await h.q(`insert into public.staff_standin values ($1)`, [staff]);
  await h.q(`insert into public.ban_standin values ($1)`, [banned]);
  const fake = (await h.one(`insert into public.channels (server_id, name, kind) values ($1, 'suggestions-new', 'text') returning id`, [other])).id;

  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '227_suggestions.sql'), 'utf8');
  await h.db.exec(sql);
  await h.ok('migration runs twice', () => h.db.exec(sql));

  const ch = await h.one(`select id, read_only, private from public.channels where server_id = $1 and name = 'suggestions-new'`, [hq]);
  h.eq('HQ channel made once, read-only and staff-only', [!!ch, ch.read_only, ch.private], [true, true, true]);
  h.eq('one HQ channel', (await h.one(`select count(*)::int n from public.channels where server_id = $1 and name = 'suggestions-new'`, [hq])).n, 1);
  h.eq('only Moderator and Admin can see it', (await h.q(`select r.name from public.channel_roles cr join public.roles r on r.id = cr.role_id where cr.channel_id = $1 order by 1`, [ch.id])).map((r) => r.name), ['Admin', 'Moderator']);
  h.eq('flag on for HQ only (test)', (await h.one(`select mode, servers = array[$1::uuid] hq from public.feature_flags where key = 'suggest_form'`, [hq])), { mode: 'test', hq: true });

  const submit = (cid, title = 'Pin DMs to the top', area = 'chat', body = 'So my best friend is always first in the list.') =>
    h.q(`select public.submit_suggestion($1, $2, $3, $4) id`, [cid, title, area, body]);

  await h.as(a);
  const first = (await submit(ch.id))[0].id;
  h.eq('submitted', !!first, true);
  const msg = await h.one(`select m.author_id, m.content from public.suggestions s join public.messages m on m.id = s.message_id where s.id = $1`, [first]);
  h.eq('posted as their own message', msg.author_id, a);
  h.eq('message has title, area and details', msg.content, '## 💡 Pin DMs to the top\n-# Chat\nSo my best friend is always first in the list.');
  await h.fails('other servers cannot use the name', `select public.submit_suggestion($1, 'Some idea here', 'chat', 'more than ten chars')`, [fake]);
  await h.fails('bad area', `select public.submit_suggestion($1, 'Some idea here', 'nonsense', 'more than ten chars')`, [ch.id]);
  await h.fails('title too short', `select public.submit_suggestion($1, 'hi', 'chat', 'more than ten chars')`, [ch.id]);
  await h.fails('details too short', `select public.submit_suggestion($1, 'Some idea here', 'chat', 'short')`, [ch.id]);
  await submit(ch.id, 'Second idea ok');
  await submit(ch.id, 'Third idea ok');
  await h.fails('4th in a day is refused', `select public.submit_suggestion($1, 'Fourth idea', 'chat', 'more than ten chars')`, [ch.id]);
  await h.fails('cannot insert rows directly', `insert into public.suggestions (user_id, title, area, body) values ($1, 'Direct insert', 'chat', 'more than ten chars')`, [a]);

  // No Send Messages: no suggestions either.
  const muted = await (async () => { await h.admin(); const u = await h.signup('m@x.com', 'muted'); await h.q(`update public.profiles set created_at = now() - interval '2 hours' where id = $1`, [u]); await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [hq, u]); await h.q(`insert into public.mute_standin values ($1)`, [u]); return u; })();
  await h.as(muted);
  await h.fails('no Send Messages permission: refused', `select public.submit_suggestion($1, 'Some idea here', 'chat', 'more than ten chars')`, [ch.id]);

  // The posted message can't be edited by its author (votes were for that text).
  await h.as(a);
  await h.fails('author cannot edit the posted suggestion', `update public.messages set content = 'something else' where id = (select message_id from public.suggestions where id = $1)`, [first]);
  h.eq('votes RPC is staff only (empty for others)', (await h.q(`select * from public.suggestion_votes(array[(select message_id from public.suggestions where id = $1)])`, [first])).length, 0);

  await h.as(b);
  await h.fails('non-members of HQ cannot submit', `select public.submit_suggestion($1, 'Some idea here', 'chat', 'more than ten chars')`, [ch.id]);
  h.eq('others cannot read them', (await h.q(`select id from public.suggestions`)).length, 0);
  await h.as(banned);
  await h.fails('site-banned cannot submit', `select public.submit_suggestion($1, 'Some idea here', 'chat', 'more than ten chars')`, [ch.id]);
  await h.as(null);
  await h.fails('logged out cannot submit', `select public.submit_suggestion($1, 'Some idea here', 'chat', 'more than ten chars')`, [ch.id]);

  await h.as(a);
  h.eq('author reads own', (await h.q(`select id from public.suggestions`)).length, 3);
  await h.q(`update public.suggestions set status = 'done' where id = $1`, [first]);
  await h.as(staff);
  h.eq('author cannot change status', (await h.one(`select status from public.suggestions where id = $1`, [first])).status, 'open');
  h.eq('staff read all', (await h.q(`select id from public.suggestions`)).length, 3);
  await h.ok('staff set status and note', () => h.q(`update public.suggestions set status = 'planned', staff_note = 'On it', updated_at = now() where id = $1`, [first]));
  h.eq('saved', (await h.one(`select status, staff_note from public.suggestions where id = $1`, [first])), { status: 'planned', staff_note: 'On it' });
  await h.fails('staff cannot edit the text', `update public.suggestions set body = 'changed by staff here' where id = $1`, [first]);
  await h.fails('unknown status refused', `update public.suggestions set status = 'maybe' where id = $1`, [first]);

  await h.admin();
  await h.q(`update public.feature_flags set mode = 'off' where key = 'suggest_form'`);
  await h.as(staff);
  await h.fails('flag off: closed', `select public.submit_suggestion($1, 'Some idea here', 'chat', 'more than ten chars')`, [ch.id]);
}
