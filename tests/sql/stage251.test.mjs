// 251: server onboarding (flag server_onboarding). Starts from stage 24 (+ flags 031/041) with stand-ins for the
// live pieces it leans on (role perms/auto, server_perm with role perms, my_top_role_position). Then 251 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists auto text not null default 'none';
alter table public.roles add column if not exists manage_server boolean not null default false;
alter table public.roles add column if not exists manage_messages boolean not null default false;
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid,
  role_id uuid, allow text[] not null default '{}', deny text[] not null default '{}');
create table if not exists public.server_bots (server_id uuid, bot text, config jsonb, enabled boolean default true);
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create or replace function public.my_top_role_position(sid uuid) returns integer language sql stable security definer set search_path = public as $$
  select coalesce(max(r.position), -1) from public.member_roles mr join public.roles r on r.id = mr.role_id
  where mr.server_id = sid and mr.user_id = auth.uid();
$$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const owner = await h.signup('o@x.com', 'owner');
  const mgr = await h.signup('m@x.com', 'manager');
  const old = await h.signup('old@x.com', 'oldtimer');
  const kid = await h.signup('n@x.com', 'newbie');
  const out = await h.signup('x@x.com', 'outsider');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  const T = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [out])).id;
  const gen = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'general', $1, $2) returning id`, [S, owner])).id;
  const start = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'start-here', $1, $2) returning id`, [S, owner])).id;
  const tChan = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'x', $1, $2) returning id`, [T, out])).id;
  for (const u of [owner, mgr, old]) await h.q(`insert into server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '1 day') on conflict do nothing`, [S, u]);
  const role = async (sid, name, pos, perms = '{}', auto = 'none') => (await h.one(
    `insert into roles (server_id, name, position, perms, auto) values ($1, $2, $3, $4::jsonb, $5) returning id`, [sid, name, pos, perms, auto])).id;
  const mgrRole = await role(S, 'Manager', 10, '{"manage_server": true, "manage_roles": true}');
  const halfRole = await role(S, 'Server only', 9, '{"manage_server": true}');
  const half = await h.signup('h@x.com', 'halfmanager');
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '1 day')`, [S, half]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, half, halfRole]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, mgr, mgrRole]);
  const gamer = await role(S, 'Gamer', 2);
  const artist = await role(S, 'Artist', 3);
  const high = await role(S, 'VIP', 20);
  const modRole = await role(S, 'Mod', 5, '{"kick_members": true}');
  const autoRole = await role(S, 'Everyone auto', 1, '{}', 'all');
  const otherRole = await role(T, 'Theirs', 1);
  const sneaky = await role(S, 'Sneaky', 1, '{"ban_members": "yes"}');
  const chanMod = await role(S, 'Channel mod', 1);
  await h.q(`insert into channel_overrides (server_id, channel_id, role_id, allow) values ($1, $2, $3, '{manage_messages}')`, [S, gen, chanMod]);
  const support = await role(S, 'Support', 1);
  await h.q(`insert into server_bots (server_id, bot, config) values ($1, 'tickets', $2::jsonb)`, [S, JSON.stringify({ support_role_id: support })]);

  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '251_server_onboarding.sql'), 'utf8');
  await h.db.exec(sql);
  await h.ok('migration runs twice', () => h.db.exec(sql));
  h.eq('flag in test mode', (await h.one(`select mode from feature_flags where key = 'server_onboarding'`)).mode, 'test');
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'server_onboarding'`, [S]);

  const cfg = (roles, extra = {}) => JSON.stringify({ enabled: true, required: true, default_channel_id: start, questions: [
    { title: 'What are you into?', multi: true, answers: [{ label: 'Games', emoji: '🎮', role_ids: roles.games ?? [gamer] }, { label: 'Art', role_ids: [artist] }] },
    { title: 'Pick one', multi: false, answers: [{ label: 'A', role_ids: [] }, { label: 'B', role_ids: [] }] }], ...extra });
  const save = (c, sid = S) => h.q(`select save_onboarding($1, $2::jsonb)`, [sid, c]);

  // Who can set it up
  await h.as(kid);
  await h.fails('non-member cannot save', `select save_onboarding($1, $2::jsonb)`, [S, cfg({})]);
  await h.as(old);
  await h.fails('member without Manage Server cannot save', `select save_onboarding($1, $2::jsonb)`, [S, cfg({})]);
  await h.as(out);
  await h.fails('flag off for that server', `select save_onboarding($1, $2::jsonb)`, [T, JSON.stringify({ enabled: true, questions: [] })]);
  await h.as(half);
  await h.fails('Manage Server without Manage Roles cannot save', `select save_onboarding($1, $2::jsonb)`, [S, cfg({})]);
  await h.as(mgr);
  await h.fails('a power set to "yes" is still power', `select save_onboarding($1, $2::jsonb)`, [S, cfg({ games: [sneaky] })]);
  await h.fails('a role that moderates a channel refused', `select save_onboarding($1, $2::jsonb)`, [S, cfg({ games: [chanMod] })]);
  await h.fails('the Tickets support role refused', `select save_onboarding($1, $2::jsonb)`, [S, cfg({ games: [support] })]);
  await h.fails('roles with mod powers refused', `select save_onboarding($1, $2::jsonb)`, [S, cfg({ games: [modRole] })]);
  await h.fails('automatic roles refused', `select save_onboarding($1, $2::jsonb)`, [S, cfg({ games: [autoRole] })]);
  await h.fails('another server\'s role refused', `select save_onboarding($1, $2::jsonb)`, [S, cfg({ games: [otherRole] })]);
  await h.fails('manager cannot use a role above their own', `select save_onboarding($1, $2::jsonb)`, [S, cfg({ games: [high] })]);
  await h.fails('another server\'s channel refused', `select save_onboarding($1, $2::jsonb)`, [S, cfg({}, { default_channel_id: tChan })]);
  await h.ok('manager saves', () => save(cfg({})));
  await h.as(owner);
  await h.ok('owner can use any safe role', () => save(cfg({ games: [gamer, high] })));
  await h.ok('saving again replaces it', () => save(cfg({})));
  await h.admin();
  h.eq('2 questions, 4 answers', (await h.one(`select (select count(*)::int from onboarding_questions where server_id = $1) q, (select count(*)::int from onboarding_answers where server_id = $1) a`, [S])), { q: 2, a: 4 });

  // Tables are not readable or writable directly
  await h.as(old);
  await h.fails('tables are closed to members', `select * from onboarding_answers`);
  await h.fails('cannot fake finishing', `insert into onboarding_choices (server_id, user_id) values ($1, $2)`, [S, old]);

  // A new member after it was switched on
  await h.admin();
  await h.q(`update server_onboarding set enabled_at = now() - interval '1 minute' where server_id = $1`, [S]);
  await h.q(`insert into server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '30 seconds')`, [S, kid]);
  const say = async (uid, cid) => { await h.as(uid); try { await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [cid, uid]); return 'ok'; } catch (e) { return String(e.message); } };
  await h.as(kid);
  const g = (await h.one(`select get_onboarding($1) g`, [S])).g;
  h.eq('new member: needed, 2 questions', [g.needed, g.questions.length, g.questions[0].answers[0].label], [true, 2, 'Games']);
  h.eq('new member cannot chat yet', (await say(kid, gen)).includes('Finish onboarding'), true);
  h.eq('member from before is never held back', await say(old, gen), 'ok');
  await h.as(old);
  h.eq('member from before is not asked', (await h.one(`select get_onboarding($1) g`, [S])).g.needed, false);
  h.eq('manager is not held back', await say(mgr, gen), 'ok');

  await h.as(kid);
  const q = g.questions;
  const picks = [q[0].answers[0].id, q[0].answers[1].id, q[1].answers[0].id, q[1].answers[1].id];
  h.eq('finishing returns the start channel', (await h.one(`select complete_onboarding($1, $2::uuid[]) c`, [S, picks])).c, start);
  const myRoles = async (uid) => (await h.q(`select r.name from member_roles mr join roles r on r.id = mr.role_id where mr.server_id = $1 and mr.user_id = $2 order by 1`, [S, uid])).map((r) => r.name);
  await h.admin();
  h.eq('got both roles from the multi question', await myRoles(kid), ['Artist', 'Gamer']);
  h.eq('only one answer kept for a single-pick question', (await h.one(`select cardinality(answer_ids) n from onboarding_choices where server_id = $1 and user_id = $2`, [S, kid])).n, 3);
  h.eq('can chat after finishing', await say(kid, gen), 'ok');

  // Redo: drop Art, keep Games
  await h.as(kid);
  await h.fails('no rapid redo', `select complete_onboarding($1, $2::uuid[])`, [S, [q[0].answers[0].id]]);
  const cool = async () => { await h.admin(); await h.q(`update onboarding_choices set done_at = done_at - interval '15 seconds'`); await h.as(kid); };
  await cool();
  await h.q(`select complete_onboarding($1, $2::uuid[])`, [S, [q[0].answers[0].id]]);
  await h.admin();
  h.eq('redo takes back the role no longer picked', await myRoles(kid), ['Gamer']);
  // A role given by hand is not taken away by a redo
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3) on conflict do nothing`, [S, kid, artist]);
  await cool();
  await h.q(`select complete_onboarding($1, $2::uuid[])`, [S, [q[0].answers[0].id]]);
  await h.admin();
  h.eq('hand-given role stays', await myRoles(kid), ['Artist', 'Gamer']);

  // A role you already had is never recorded as onboarding's, so a redo can't take it.
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, old, artist]);
  await h.as(old);
  await h.q(`select complete_onboarding($1, $2::uuid[])`, [S, [q[0].answers[1].id]]);
  await h.admin(); await h.q(`update onboarding_choices set done_at = done_at - interval '1 minute'`);
  await h.as(old);
  await h.q(`select complete_onboarding($1, '{}'::uuid[])`, [S]);
  await h.admin();
  h.eq('role from before onboarding stays after a redo', await myRoles(old), ['Artist']);

  // Leave and come back: onboarding again.
  await h.q(`update server_members set joined_at = now() + interval '1 minute' where server_id = $1 and user_id = $2`, [S, kid]);
  await h.as(kid);
  h.eq('rejoined member has to do it again', (await h.one(`select get_onboarding($1) g`, [S])).g.needed, true);
  h.eq('and is held back again', (await say(kid, gen)).includes('Finish onboarding'), true);

  await h.as(kid);
  await h.fails('answers of another server do nothing harmful (outsider cannot complete)', `select complete_onboarding($1, '{}'::uuid[])`, [T]);
  await h.as(out);
  h.eq('non-member gets nothing', (await h.one(`select get_onboarding($1) g`, [S])).g, null);
}
