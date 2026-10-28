// 516: stage channels. Starts from stage 24 with the flags tables and stand-ins for server_perm with role perms and
// is_staff, then 516 twice: only voice channels can be stages, stage_role answers mod / listener / null (not a stage,
// flag off or not in the test servers, can't see the channel), stage_role_for answers for someone else and is
// service role only, and it puts the caller's claims back.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '516_stage_channels.sql'), 'utf8');

const STANDINS = `
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists private boolean default false, add column if not exists read_only boolean default false,
  add column if not exists slowmode int default 0, add column if not exists no_images boolean default false, add column if not exists no_gifs boolean default false,
  add column if not exists category_id uuid, add column if not exists ticket_by uuid;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create table if not exists public.staff_standin (id uuid primary key);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_standin where id = auth.uid())
$$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`516 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  const owner = await h.signup('o@x.com', 'owner');
  const mod = await h.signup('m@x.com', 'stagemod');
  const member = await h.signup('u@x.com', 'member');
  const outsider = await h.signup('x@x.com', 'outsider');
  const staff = await h.signup('s@x.com', 'staffer');
  await h.admin();
  await h.q(`insert into staff_standin (id) values ($1)`, [staff]);
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  const S2 = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner])).id;
  for (const u of [owner, mod, member]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  for (const u of [member, staff]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S2, u]);
  const modRole = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Stage mod', 5, '{"mute_members": true}'::jsonb) returning id`, [S])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, mod, modRole]);
  const chan = async (sid, kind, name) => (await h.one(`insert into channels (server_id, kind, name, created_by, position) values ($1, $2, $3, $4, 9) returning id`, [sid, kind, name, owner])).id;
  const stage = await chan(S, 'voice', 'Q and A');
  const plainVoice = await chan(S, 'voice', 'Hangout');
  const text = await chan(S, 'text', 'general');
  const otherStage = await chan(S2, 'voice', 'Elsewhere');

  await h.ok('516 runs', () => h.db.exec(MIG));
  await h.ok('516 runs again', () => h.db.exec(MIG));

  await h.q(`update channels set stage = true where id in ($1, $2)`, [stage, otherStage]);
  await h.fails('a text channel can’t be a stage', `update channels set stage = true where id = $1`, [text]);
  h.eq('flag row is in test mode for the HQ test server only', await h.one(`select mode, servers::text[] as servers, users::text[] as users from feature_flags where key = 'stage_channels'`),
    { mode: 'test', servers: ['00000000-0000-4000-8000-00000000b001'], users: [] });
  await h.ok('the audit trigger watches stage', async () => {
    const t = await h.one(`select pg_get_triggerdef(oid) as d from pg_trigger where tgname = 'channels_audit'`);
    if (!/\bstage\b/.test(t.d)) throw new Error(t.d);
  });
  // Put this test's server in the test list (the real row lists HQ's test server).
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'stage_channels'`, [S]);

  const role = async (uid, cid) => { await h.as(uid); const r = (await h.one(`select public.stage_role($1) as r`, [cid])).r; await h.admin(); return r; };
  h.eq('member joins the stage as a listener', await role(member, stage), 'listener');
  h.eq('Mute Members makes a stage mod', await role(mod, stage), 'mod');
  h.eq('the owner is a stage mod', await role(owner, stage), 'mod');
  h.eq('a plain voice channel is not a stage', await role(member, plainVoice), null);
  h.eq('a text channel is not a stage', await role(member, text), null);
  h.eq('someone outside the server gets nothing', await role(outsider, stage), null);
  h.eq('a server outside the test list: off', await role(member, otherStage), null);
  h.eq('signed out: null', (await (async () => { await h.as(null); const r = await h.one(`select public.stage_role($1) as r`, [stage]).catch(() => ({ r: 'refused' })); await h.admin(); return r.r; })()), 'refused');

  await h.q(`update feature_flags set mode = 'off' where key = 'stage_channels'`);
  h.eq('flag off: not a stage', await role(member, stage), null);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'stage_channels'`);
  h.eq('flag on for everyone: other servers too', await role(member, otherStage), 'listener');
  h.eq('Yapin’ staff are stage mods without a role', await role(staff, otherStage), 'mod');
  await h.q(`update feature_flags set mode = 'test' where key = 'stage_channels'`);

  // stage_role_for: service role only; puts the caller's claims back.
  await h.as(member);
  await h.fails('members can’t call stage_role_for', `select public.stage_role_for($1, $2)`, [mod, stage]);
  await h.admin();
  await h.db.exec(`set role service_role`).catch(() => undefined);
  await h.ok('service role asks for someone else', async () => {
    const before = (await h.one(`select current_setting('request.jwt.claim.sub', true) as s`)).s;
    h.eq('listener for the member', (await h.one(`select public.stage_role_for($1, $2) as r`, [member, stage])).r, 'listener');
    h.eq('mod for the mod', (await h.one(`select public.stage_role_for($1, $2) as r`, [mod, stage])).r, 'mod');
    // Fail closed: callers treat null as "free to talk", so on a live stage it's listener even without access.
    h.eq('listener for an outsider on a live stage', (await h.one(`select public.stage_role_for($1, $2) as r`, [outsider, stage])).r, 'listener');
    h.eq('null for a plain voice channel', (await h.one(`select public.stage_role_for($1, $2) as r`, [member, plainVoice])).r, null);
    h.eq('null for a stage outside the test servers', (await h.one(`select public.stage_role_for($1, $2) as r`, [member, otherStage])).r, null);
    h.eq('claims put back', (await h.one(`select current_setting('request.jwt.claim.sub', true) as s`)).s, before);
  });
  await h.admin();
  h.eq('anon can’t run stage_role', (await h.one(`select has_function_privilege('anon', 'public.stage_role(uuid)', 'execute') as x`)).x, false);
  h.eq('authenticated can’t run stage_role_for', (await h.one(`select has_function_privilege('authenticated', 'public.stage_role_for(uuid, uuid)', 'execute') as x`)).x, false);
}
