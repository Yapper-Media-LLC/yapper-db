// 517: reorder_roles gives a manager's roles distinct places (roles that shared a position snapped back), has_hate
// no longer reads bare uuids or hex runs as 1488, set_channel_posting takes Manage Channels, flag member_list_access.
// Starts from stage 24 with stand-ins for role perms / server_perm (as in 504) and the filter pieces (as in 481).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('517_bug_queue_roles_filter.sql');

const STANDINS = String.raw`
set check_function_bodies = off;
create schema if not exists extensions;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$ select t $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
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
alter table public.roles add column if not exists perms jsonb not null default '{}';
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`517 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('430_filter_bypasses.sql'));
  await h.db.exec(mig('481_filter_ids_plusminus.sql'));
  await h.ok('517 runs', () => h.db.exec(MIG));
  await h.ok('517 re-runs cleanly', () => h.db.exec(MIG));

  // has_hate: what the reports hit is let through now, the real thing is still caught.
  const hate = async (t) => (await h.one(`select public.has_hate($1) v`, [t])).v;
  h.eq('bare uuid in an emoji url passes', await hate('https://x.yapin.gg/emojis/3fa1488c-1d2e-4a2b-9c3d-0123456789ab.png'), false);
  h.eq('bare uuid with 1488 in the last part passes', await hate('role 0f0e0d0c-1d2e-4a2b-9c3d-012345148800'), false);
  h.eq('long hex file key passes', await hate('k/9f3e1488aa00bb11cc22dd33.png'), false);
  h.eq('short hex word with 1488 still caught', await hate('aaa1488'), true);
  h.eq('all-digit uuid shape still caught', await hate('88888888-1488-1488-1488-148814881488'), true);
  h.eq('1488 padded into a run with one letter still caught', await hate('1488a00000000000'), true);
  h.eq('1488 next to a file key still caught', await hate('1488 a0b1c2d3e4f5a6b7c8d9'), true);
  h.eq('wrapped role ping still passes', await hate('<@&3fa1488c-1d2e-4a2b-9c3d-0123456789ab>'), false);
  h.eq('plain 1488 still caught', await hate('1488'), true);
  h.eq('14/88 still caught', await hate('we are 14/88'), true);
  h.eq('aa1488 (short) still caught', await hate('aa1488'), true);
  h.eq('1488 in a sentence still caught', await hate('the number is 1488 ok'), true);
  h.eq('swastika still caught', await hate('卐'), true);
  h.eq('ordinary text passes', await hate('pick your yellow role here'), false);

  // reorder_roles: a manager whose roles share positions can now reorder them.
  const owner = await h.signup('o@x.com', 'owner');
  const mgr = await h.signup('m@x.com', 'manager');
  const plainUser = await h.signup('p@x.com', 'plain');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  for (const u of [owner, mgr, plainUser]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  const role = async (name, pos, perms = '{}') => (await h.one(
    `insert into roles (server_id, name, position, perms) values ($1, $2, $3, $4::jsonb) returning id`, [S, name, pos, perms])).id;
  const top = await role('Top', 30, '{"administrator": true}');
  const mgrRole = await role('Manager', 2, '{"manage_roles": true}');
  const a = await role('A', 1);
  const b = await role('B', 1);
  const c = await role('C', 1);
  const d = await role('D', 0);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, mgr, mgrRole]);
  const pos = async () => {
    await h.admin();
    const rows = await h.q(`select id, position from roles where server_id = $1`, [S]);
    return Object.fromEntries((rows.rows ?? rows).map((r) => [r.id, r.position]));
  };
  const call = async (by, ids) => { await h.as(by); return h.q(`select public.reorder_roles($1, $2::uuid[])`, [S, ids]); };

  await h.ok('manager reorders tied roles', () => call(mgr, [top, mgrRole, c, a, d, b]));
  let p = await pos();
  h.eq('order below the manager is the one asked for', [c, a, d, b].map((x) => p[x]).join(','), '3,2,1,0');
  h.eq('places are distinct', new Set([c, a, d, b].map((x) => p[x])).size, 4);
  h.eq('manager stays above them', p[mgrRole] > p[c], true);
  h.eq('top stays above the manager', p[top] > p[mgrRole], true);
  // The manager's top role moved up to make room (2 -> 4), so their roles still sit below it.
  h.eq('manager role made room', p[mgrRole], 4);

  // Swapping two that used to tie works both ways now.
  await h.ok('swap a and c', () => call(mgr, [top, mgrRole, a, c, d, b]));
  p = await pos();
  h.eq('a above c', p[a] > p[c], true);

  // Still refused: moving the manager's own role or one above it, and people without Manage Roles.
  await h.as(mgr);
  await h.fails('manager cannot put a role above their own', `select public.reorder_roles($1, $2::uuid[])`, [S, [top, a, mgrRole, c, d, b]]);
  await h.as(plainUser);
  await h.fails('member without Manage Roles refused', `select public.reorder_roles($1, $2::uuid[])`, [S, [top, mgrRole, b, a, c, d]]);

  // The owner path is unchanged.
  await h.ok('owner reorders everything', () => call(owner, [mgrRole, top, a, b, c, d]));
  p = await pos();
  h.eq('owner order applied', [mgrRole, top, a, b, c, d].map((x) => p[x]).join(','), '5,4,3,2,1,0');

  // set_channel_posting: Manage Channels is enough now, a plain member is still refused.
  await h.admin();
  const chRole = await role('Channels', 0, '{"manage_channels": true}');
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, plainUser, chRole]);
  const ch = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'news', 'text') returning id`, [S])).id;
  await h.as(plainUser);
  await h.ok('Manage Channels sets read-only', () => h.q(`select public.set_channel_posting($1, true, $2::uuid[], 0)`, [ch, [mgrRole]]));
  await h.admin();
  h.eq('channel is read-only', (await h.one(`select read_only from channels where id = $1`, [ch])).read_only, true);
  h.eq('posting role saved', Number((await h.one(`select count(*) n from channel_post_roles where channel_id = $1`, [ch])).n), 1);
  await h.as(mgr);
  await h.fails('Manage Roles alone cannot', `select public.set_channel_posting($1, false, '{}'::uuid[], 0)`, [ch]);

  await h.admin();
  h.eq('flag member_list_access in test', (await h.one(`select mode from feature_flags where key = 'member_list_access'`))?.mode, 'test');
}
