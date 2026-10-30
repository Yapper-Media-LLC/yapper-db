// 688 ping roles + 690 role_members. Starts from stage 24 with stand-ins for what came later: feature flags, the role
// columns (perms, auto, mentionable), my_top_role_position, onboarding_role_ok (simplified to "no perms, not auto"),
// can_give_role_perms (stand-in: nobody may give attach_files),
// webhook_hit (155) and member_lookup_ok (524, with servers.member_count and server_members.nickname).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const PING = mig('688_ping_roles.sql');
const FOLD = mig('689_folder_custom.sql');
const RM = mig('690_role_mention_members.sql');

const STANDINS = String.raw`
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[] default '{}', users uuid[] default '{}');
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false);
$$;
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists auto text not null default 'none';
alter table public.roles add column if not exists mentionable boolean not null default false;
alter table public.servers add column if not exists member_count int not null default 0;
alter table public.server_members add column if not exists nickname text;
alter table public.profiles add column if not exists display_name text;
create or replace function public.my_top_role_position(sid uuid) returns int language sql stable security definer set search_path = public as $$
  select coalesce((select max(r.position) from public.member_roles mr join public.roles r on r.id = mr.role_id
                   where mr.server_id = sid and mr.user_id = auth.uid()), -1);
$$;
create or replace function public.onboarding_role_ok(sid uuid, rid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.roles r where r.id = rid and r.server_id = sid and r.auto = 'none'
    and not r.manage_server and not r.manage_messages
    and not exists (select 1 from jsonb_each_text(r.perms) p(k, v) where v <> 'false' and k not in ('send_messages', 'attach_files')));
$$;
create or replace function public.can_give_role_perms(sid uuid, rid uuid) returns boolean language sql stable set search_path = public as $$
  select public.server_perm(sid, 'manage_roles') and not exists (select 1 from public.roles r where r.id = rid and r.perms ? 'attach_files');
$$;
create table if not exists public.webhook_rate (k text not null, bucket bigint not null, n int not null default 0, at timestamptz not null default now(), primary key (k, bucket));
create or replace function public.webhook_hit(k text, win int, lim int) returns numeric
language plpgsql security definer set search_path = public as $$
declare e numeric := extract(epoch from clock_timestamp()); b bigint := floor(e / win); got int;
begin
  insert into public.webhook_rate as r (k, bucket, n) values (k, b, 1)
    on conflict on constraint webhook_rate_pkey do update set n = r.n + 1 where r.n < lim
    returning r.n into got;
  if got is null then return greatest(0.001, round((b + 1) * win - e, 3)); end if;
  return 0;
end $$;
create or replace function public.webhook_hit_n(k text, win int, lim int, cost int) returns numeric
language sql security definer set search_path = public as $$ select 0::numeric $$;
create or replace function public.member_lookup_ok(sid uuid, kind text, cost int) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  return exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me);
end $$;
`;

export default async function (h) {
  for (const [name, src] of [['688', PING], ['689', FOLD], ['690', RM]]) {
    for (const bad of ['drop', 'delete from', 'truncate']) {
      if (src.toLowerCase().includes(bad)) throw new Error(`${name} contains "${bad}" (the Supabase MCP hangs on it)`);
    }
  }
  const owner = await h.signup('owner@x.test', 'owner');
  const mod = await h.signup('mod@x.test', 'mod');
  const me = await h.signup('me@x.test', 'zed');
  const amy = await h.signup('amy@x.test', 'amy');
  const out = await h.signup('out@x.test', 'outsider');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('688 runs', () => h.db.exec(PING));
  await h.ok('688 re-runs cleanly', () => h.db.exec(PING));
  await h.ok('689 runs twice', async () => { await h.db.exec(FOLD); await h.db.exec(FOLD); });
  await h.ok('690 runs', () => h.db.exec(RM));
  await h.ok('690 re-runs cleanly', () => h.db.exec(RM));
  h.eq('three flags, all test', (await h.q(`select key, mode from public.feature_flags order by key`)).map((r) => `${r.key}:${r.mode}`),
    ['folder_custom:test', 'ping_roles:test', 'role_mention_members:test']);

  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  const off = (await h.one(`insert into public.servers (name, owner_id) values ('Off', $1) returning id`, [owner])).id;
  await h.q(`update public.feature_flags set servers = array[$1::uuid] where key in ('ping_roles', 'role_mention_members')`, [sid]);
  for (const s of [sid, off]) for (const u of [owner, mod, me, amy]) await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [s, u]);
  const role = async (s, name, pos, extra = '') => (await h.one(`insert into public.roles (server_id, name, position${extra ? ', perms' : ''}) values ($1, $2, $3${extra ? `, '${extra}'::jsonb` : ''}) returning id`, [s, name, pos])).id;
  const modRole = (await h.one(`insert into public.roles (server_id, name, position, manage_server) values ($1, 'Mod', 10, true) returning id`, [sid])).id;
  await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, mod, modRole]);
  const high = await role(sid, 'High', 20);
  const banny = await role(sid, 'Banny', 2, '{"ban_members": true}');
  const offRole = await role(off, 'Giveaways', 0);

  // ---- template ----
  const tpl = JSON.stringify([{ name: 'Announcements', emoji: '📢' }, { name: 'Giveaways', emoji: '🎁' }, { name: 'Polls' }]);
  await h.as(me);
  await h.fails('template: plain members can not', `select public.ping_roles_template($1, $2::jsonb)`, [sid, tpl]);
  await h.as(owner);
  await h.fails('template: flag off in that server', `select public.ping_roles_template($1, $2::jsonb)`, [off, tpl]);
  h.eq('template: owner adds 3', (await h.one(`select public.ping_roles_template($1, $2::jsonb) n`, [sid, tpl])).n, 3);
  h.eq('template: again adds none (same names reused)', (await h.one(`select public.ping_roles_template($1, $2::jsonb) n`, [sid, tpl])).n, 0);
  const made = await h.q(`select r.id, r.name, r.position, r.color, p.emoji, p.position pp from public.ping_roles p join public.roles r on r.id = p.role_id where p.server_id = $1 order by p.position`, [sid]);
  h.eq('template: names in order', made.map((r) => r.name), ['Announcements', 'Giveaways', 'Polls']);
  h.eq('template: at the bottom, no colour', made.every((r) => r.position === 0 && r.color === null), true);
  h.eq('template: emoji kept', made[0].emoji, '📢');
  await h.fails('template: a same-named role with perms is refused', `select public.ping_roles_template($1, '[{"name":"banny"}]'::jsonb)`, [sid]);
  await h.fails('template: name too long', `select public.ping_roles_template($1, $2::jsonb)`, [sid, JSON.stringify([{ name: 'x'.repeat(33) }])]);
  const [ann, give, polls] = made.map((r) => r.id);

  // ---- save (settings) ----
  await h.as(mod);
  await h.fails('save: a manager can not add a role above them', `select public.save_ping_roles($1, $2::jsonb)`, [sid, JSON.stringify([{ role_id: high }])]);
  await h.fails('save: a role with perms is refused', `select public.save_ping_roles($1, $2::jsonb)`, [sid, JSON.stringify([{ role_id: banny }])]);
  await h.fails('save: a role from another server is refused', `select public.save_ping_roles($1, $2::jsonb)`, [sid, JSON.stringify([{ role_id: offRole }])]);
  // Posting rights in a read-only channel and permissions the manager lacks (504) both keep a role out.
  await h.admin();
  const chan = (await h.one(`insert into public.channels (kind, name, server_id, created_by) values ('text', 'news', $1, $2) returning id`, [sid, owner])).id;
  const poster = await role(sid, 'Poster', 1);
  await h.q(`insert into public.channel_post_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [chan, poster, sid]);
  const attach = (await h.one(`insert into public.roles (server_id, name, position, perms) values ($1, 'Attach', 1, '{"attach_files": true}') returning id`, [sid])).id;
  await h.as(mod);
  await h.fails('save: a role that can post in read-only channels is refused', `select public.save_ping_roles($1, $2::jsonb)`, [sid, JSON.stringify([{ role_id: poster }])]);
  await h.fails('save: a role with a perm the manager can not give is refused', `select public.save_ping_roles($1, $2::jsonb)`, [sid, JSON.stringify([{ role_id: attach }])]);
  await h.fails('ping_role_ok is not callable directly', `select public.ping_role_ok($1, $2)`, [sid, attach]);
  await h.as(owner);
  await h.fails('save: the 504 rule holds for owners too (stand-in refuses attach_files)', `select public.save_ping_roles($1, $2::jsonb)`, [sid, JSON.stringify([{ role_id: attach }])]);
  await h.as(mod);
  await h.ok('save: manager reorders + drops one', () => h.q(`select public.save_ping_roles($1, $2::jsonb)`, [sid, JSON.stringify([{ role_id: polls, blurb: ' Vote on stuff ' }, { role_id: ann }])]));
  h.eq('save: new order', (await h.q(`select role_id, blurb from public.ping_roles where server_id = $1 order by position`, [sid])).map((r) => [r.role_id, r.blurb]), [[polls, 'Vote on stuff'], [ann, null]]);
  await h.as(me);
  await h.fails('save: plain member refused', `select public.save_ping_roles($1, '[]'::jsonb)`, [sid]);
  h.eq('members can read the list', (await h.q(`select role_id from public.ping_roles where server_id = $1`, [sid])).length, 2);
  await h.fails('members can not write the table', `insert into public.ping_roles (role_id, server_id) values ($1, $2)`, [give, sid]);
  await h.as(out);
  h.eq('outsiders read nothing', (await h.q(`select role_id from public.ping_roles`)).length, 0);

  // ---- members pick ----
  await h.as(me);
  const mine = async () => (await h.q(`select role_id from public.member_roles where server_id = $1 and user_id = $2 order by role_id`, [sid, me])).map((r) => r.role_id).sort();
  h.eq('pick: only ping roles stick', (await h.one(`select public.set_my_ping_roles($1, $2::uuid[]) v`, [sid, [polls, high, give, modRole]])).v, [polls]);
  h.eq('pick: has polls', await mine(), [polls]);
  await h.q(`select public.set_my_ping_roles($1, $2::uuid[])`, [sid, [ann]]);
  h.eq('pick: swap to announcements', await mine(), [ann]);
  await h.as(owner);
  await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, me, high]);
  await h.as(me);
  await h.q(`select public.set_my_ping_roles($1, '{}'::uuid[])`, [sid]);
  h.eq('pick: clearing leaves other roles alone', await mine(), [high]);
  await h.as(out);
  await h.fails('pick: outsiders refused', `select public.set_my_ping_roles($1, $2::uuid[])`, [sid, [ann]]);
  await h.as(me);
  await h.fails('pick: flag off there', `select public.set_my_ping_roles($1, '{}'::uuid[])`, [off]);
  await h.as(null);
  await h.fails('pick: anon refused', `select public.set_my_ping_roles($1, '{}'::uuid[])`, [sid]);
  // A ping role later given permissions can't be picked up any more.
  await h.admin();
  await h.q(`update public.roles set perms = '{"kick_members": true}' where id = $1`, [polls]);
  await h.as(me);
  h.eq('pick: role with perms now skipped', (await h.one(`select public.set_my_ping_roles($1, $2::uuid[]) v`, [sid, [polls, ann]])).v, [ann]);

  // ---- role_members ----
  await h.admin();
  await h.q(`update public.profiles set display_name = 'Bea' where id = $1`, [amy]);
  await h.q(`update public.server_members set nickname = 'Al' where server_id = $1 and user_id = $2`, [sid, mod]);
  for (const u of [owner, mod, amy]) await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3) on conflict do nothing`, [sid, u, ann]);
  await h.as(me);
  const page = (args) => h.q(`select user_id, sort_key, total from public.role_members($1, $2, $3, $4, $5)`, args);
  const p1 = await page([ann, null, null, null, 2]);
  h.eq('members: first page by shown name', p1.map((r) => r.sort_key), ['al', 'bea']);
  h.eq('members: total on page 1', Number(p1[0].total), 4);
  const p2 = await page([ann, null, p1[1].sort_key, p1[1].user_id, 2]);
  h.eq('members: next page', p2.map((r) => r.sort_key), ['owner', 'zed']);
  h.eq('members: no total after page 1', Number(p2[0].total), -1);
  h.eq('members: last page empty', (await page([ann, null, p2[1].sort_key, p2[1].user_id, 2])).length, 0);
  const s = await page([ann, 'BE', null, null, 40]);
  h.eq('members: search by display name', s.map((r) => r.user_id), [amy]);
  h.eq('members: search total', Number(s[0].total), 1);
  h.eq('members: search with % matches nothing extra', (await page([ann, '%', null, null, 40])).length, 0);
  await h.as(out);
  h.eq('members: outsiders get nothing', (await page([ann, null, null, null, 40])).length, 0);
  await h.admin();
  const everyone = (await h.one(`insert into public.roles (server_id, name, position, auto) values ($1, 'All', 1, 'all') returning id`, [sid])).id;
  await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, amy, everyone]);
  await h.as(me);
  await h.admin();
  await h.q(`update public.feature_flags set servers = '{}' where key = 'role_mention_members'`);
  await h.as(me);
  h.eq('members: flag off, nothing', (await page([ann, null, null, null, 40])).length, 0);
  await h.admin();
  await h.q(`update public.feature_flags set servers = array[$1::uuid] where key = 'role_mention_members'`, [sid]);
  await h.as(me);
  h.eq('members: automatic roles return nothing', (await page([everyone, null, null, null, 40])).length, 0);
  await h.as(null);
  await h.fails('members: anon refused', `select * from public.role_members($1)`, [ann]);
}
