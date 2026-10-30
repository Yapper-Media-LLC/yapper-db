// 651: Art / Dev Managers as server staff (a server role each; Dev Managers lose the bot powers). 537's stand-ins, 634's deco and bot stand-ins, 634 and 635, then 651 on a
// test copy of the two servers (fixed ids, a moderation tier each, like the live ones on Oct 28).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';
import { MORE } from './stage634.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('651_area_managers_server_staff.sql');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const ART = '00000000-0000-4000-8000-00000000b004';
const DEV = '00000000-0000-4000-8000-00000000b005';

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`651 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(`alter table public.profiles add column if not exists muted_until timestamptz;
    alter table public.roles add column if not exists perms jsonb not null default '{}';
    create table if not exists public.notices (topic text, event text, payload jsonb);
    create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language sql as $$
      insert into public.notices values (topic_name, event_name, payload) $$;
    create or replace function public.hq_head_mod_role_id() returns uuid language sql immutable as $$ select '3650f1e2-7c4b-4d9a-8e21-5a6b7c8d9e01'::uuid $$;
    create or replace function public.hq_management_role_id() returns uuid language sql immutable as $$ select 'c9c2a8dd-196a-4bf7-b23b-309f94ba1cc6'::uuid $$;
    create or replace function public.modserver_management_role_id() returns uuid language sql immutable as $$ select 'f7d69cb5-8e0c-4fd8-aa62-2f04c76dcc4a'::uuid $$;`);
  await h.q(`insert into feature_flags (key, label, mode) values ('head_mods', 'x', 'everyone'), ('head_mod_badges', 'x', 'everyone'), ('mod_bot_review', 'x', 'everyone') on conflict (key) do nothing`);
  await h.db.exec(mig('634_area_managers.sql'));
  await h.db.exec(mig('635_area_applications.sql'));

  const admin = await h.signup('admin@test.dev', 'boss');
  const artOwner = await h.signup('owner@test.dev', 'artowner');
  const art = await h.signup('art@test.dev', 'artmgr');
  const dev = await h.signup('dev@test.dev', 'devmgr');
  const mod = await h.signup('mod@test.dev', 'modder');
  const u = await h.signup('u@test.dev', 'someone');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`update profiles set created_at = now() - interval '60 days'`);
  await h.q(`update feature_flags set users = users || $1::uuid || $2::uuid || $3::uuid || $4::uuid where key = 'area_managers'`, [admin, art, dev, u]);
  // The two servers as they are live: Artists isn't Antic's; each has a moderation tier and member roles under it.
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Official Yapper Artists', $3), ($2, 'Yapper Developers', $4)`, [ART, DEV, artOwner, admin]);
  await h.q(`insert into roles (server_id, name, position, perms, manage_server, manage_messages) values
    ($1, 'Owner', 4, '{}', false, false),
    ($1, 'Yapper Moderation', 2, '{"kick_members": true, "ban_members": true, "manage_server": true}', false, false),
    ($1, 'Verified Artists', 1, '{}', false, false),
    ($2, 'Staff', 5, '{"administrator": true}', true, true),
    ($2, 'Moderator', 4, '{"kick_members": true, "timeout_members": true}', false, true),
    ($2, 'Verified Developer', 3, '{}', false, false),
    ($2, 'Developer', 1, '{}', false, false)`, [ART, DEV]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $3), ($1, $5), ($2, $4), ($1, $6), ($2, $6), ($2, $7)`, [ART, DEV, artOwner, admin, art, u, mod]);

  await h.ok('651 runs', () => h.db.exec(MIG));
  await h.ok('651 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('bot flag put back', (await h.one(`select coalesce(current_setting('yapper.bot', true), '') v`)).v, '');
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const once = async (fn, marker) => (await h.one(`select (length(prosrc) - length(replace(prosrc, $2, ''))) / length($2) n from pg_proc where proname = $1`, [fn, marker])).n;
  h.eq('admin_set_badge still lets Art Managers give Artist', await once('admin_set_badge', 'is_art_manager'), 1);
  h.eq('review_community_deco still open to Art Managers', await once('review_community_deco', 'is_art_manager'), 1);
  h.eq('staff_bot_promotions back to staff', await once('staff_bot_promotions', 'is_dev_manager'), 0);
  h.eq('staff_end_bot_promotion back to staff', await once('staff_end_bot_promotion', 'is_dev_manager'), 0);
  h.eq('staff_suspend_bot admins only', await once('staff_suspend_bot', 'is_dev_manager'), 0);
  h.eq('staff_dev_report admins only', await once('staff_dev_report', 'is_dev_manager'), 0);

  // The roles: made once, under the moderation tier, above the member roles, with the Moderator tier's permissions.
  const order = async (sid) => (await h.q(`select name from roles where server_id = $1 order by position desc`, [sid])).map((r) => r.name);
  h.eq('Artists: under Yapper Moderation', await order(ART), ['Owner', 'Yapper Moderation', 'Art Manager', 'Verified Artists']);
  h.eq('Developers: under Moderator', await order(DEV), ['Staff', 'Moderator', 'Dev Manager', 'Verified Developer', 'Developer']);
  h.eq('one role each', (await h.one(`select count(*)::int n from roles where name in ('Art Manager', 'Dev Manager')`)).n, 2);
  h.eq('fixed ids', (await h.one(`select count(*)::int n from roles where id in (area_role_id('art'), area_role_id('dev'))`)).n, 2);
  const perms = (await h.one(`select perms from roles where id = area_role_id('dev')`)).perms;
  h.eq('moderation permissions', Object.keys(perms).sort(), ['kick_members', 'manage_messages', 'manage_nicknames', 'move_members', 'mute_members', 'timeout_members', 'view_audit_log']);
  h.eq('no ban, no manage server, no manage roles', [perms.ban_members, perms.manage_server, perms.manage_roles, perms.administrator], [undefined, undefined, undefined, undefined]);
  h.eq('legacy switches off', await h.one(`select manage_server, manage_messages from roles where id = area_role_id('art')`), { manage_server: false, manage_messages: false });

  // Giving the role: in the server, at once; not in it yet, when they join.
  const held = async (uid, area) => (await h.one(`select exists (select 1 from member_roles where user_id = $1 and role_id = area_role_id($2)) h`, [uid, area])).h;
  await h.as(admin);
  await h.ok('admin makes an Art Manager', () => h.q(`select admin_set_area_manager($1, 'art', true)`, [art]));
  await h.ok('admin makes a Dev Manager', () => h.q(`select admin_set_area_manager($1, 'dev', true)`, [dev]));
  await h.admin();
  h.eq('art manager has the role', await held(art, 'art'), true);
  h.eq('dev manager not in the server: no role yet', await held(dev, 'dev'), false);
  h.eq('bot flag put back after the sync', (await h.one(`select coalesce(current_setting('yapper.bot', true), '') v`)).v, '');
  await h.as(admin);
  h.eq('list says so', (await h.q(`select area, in_server, has_role from area_managers_list() order by area`)),
    [{ area: 'art', in_server: true, has_role: true }, { area: 'dev', in_server: false, has_role: false }]);
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [DEV, dev]);
  h.eq('joins: role given', await held(dev, 'dev'), true);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [ART, dev]);
  h.eq('joining the other server gives nothing', await held(dev, 'art'), false);
  h.eq('assigned by the system, not a person', await h.one(`select manual from member_roles where user_id = $1 and role_id = area_role_id('dev')`, [dev]), { manual: true });
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [DEV, dev]);
  h.eq('leaves: role gone', await held(dev, 'dev'), false);
  // Joining as themselves (auth.uid() set, not an admin): the join trigger hands the role out through the sync marker.
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [dev]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [DEV, dev]);
  await h.admin();
  h.eq('back: role back', await held(dev, 'dev'), true);
  h.eq('sync marker put back', (await h.one(`select coalesce(current_setting('yapper.staff_sync', true), '') v`)).v, '');
  await h.as(dev);
  h.eq('desk card', (await h.one(`select my_area_desk() d`)).d.map((x) => [x.area, x.server_name, x.role_name, x.in_server, x.has_role, !!x.channel_id]),
    [['dev', 'Yapper Developers', 'Dev Manager', true, true, true]]);
  await h.as(u);
  h.eq('no desk for others', (await h.one(`select my_area_desk() d`)).d, []);
  h.eq('plain user cannot list managers', await err(`select * from area_managers_list()`), 'Staff only');
  await h.as(mod);
  h.eq('mod reads the list', (await h.one(`select count(*)::int n from area_managers_list()`)).n, 2);

  // The application path gives the role too.
  await h.as(u);
  await h.ok('applies for dev', () => h.q(`select apply_area_manager('dev', 'I build bots and know the API inside out, happy to help', '', '', true)`));
  await h.admin();
  const app = (await h.one(`select id from area_applications where user_id = $1 and area = 'dev'`, [u])).id;
  await h.as(admin);
  await h.ok('admin accepts', () => h.q(`select decide_area_application($1, true)`, [app]));
  await h.admin();
  h.eq('accepted: role on', await held(u, 'dev'), true);

  // Dev Managers: server staff, nothing site-wide.
  const bot = (await h.one(`insert into bots (owner_id, name, public, verified_at) values ($1, 'Live', true, now()) returning id`, [u])).id;
  await h.q(`insert into bot_promotions (bot_id, ends_at) values ($1, now() + interval '3 days')`, [bot]);
  await h.as(dev);
  h.eq('dev manager: still an area manager', (await h.one(`select my_areas() a`)).a, ['dev']);
  h.eq('cannot suspend a bot', await err(`select staff_suspend_bot($1, 'spamming people')`, [bot]), 'Admins only');
  h.eq('cannot read the dev report', await err(`select staff_dev_report()`), 'Admins only');
  h.eq('cannot see bot promotions', await err(`select * from staff_bot_promotions()`), 'Staff only');
  h.eq('cannot end a promotion', await err(`select staff_end_bot_promotion(gen_random_uuid(), 'why')`), 'Staff only');
  h.eq('cannot review bots', await err(`select admin_verify_bot($1, true)`, [bot]), 'Moderators only');
  h.eq('still reads dev applications', (await h.q(`select area from area_applications_list()`)).length, 0);
  await h.admin();
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [dev]);
  h.eq('mod_guard pass-through: nothing for dev', (await h.one(`select area_manager_may('bot_promo') a, area_manager_may('bot_review') b`)), { a: false, b: false });
  await h.as(admin);
  await h.ok('admin still suspends and reads the report', () => h.q(`select staff_suspend_bot($1, 'spamming people'), staff_dev_report()`, [bot]));

  // Art Managers: review, badge and report exactly as in 634, plus the role.
  await h.admin();
  const deco = (await h.one(`insert into community_decos (name, artist_id, path) values ('Hat', $1, 'a/hat.png') returning id`, [u])).id;
  const deco2 = (await h.one(`insert into community_decos (name, artist_id, path) values ('Cap', $1, 'a/cap.png') returning id`, [u])).id;
  await h.as(art);
  h.eq('art manager reads pending decos', (await h.one(`select count(*)::int n from community_decos where status = 'pending'`)).n, 2);
  await h.ok('art manager reviews a deco', () => h.q(`select review_community_deco($1, 'approved')`, [deco]));
  await h.ok('art manager gives Artist', () => h.q(`select admin_set_badge($1, 'artist', true)`, [u]));
  await h.ok('art manager reads the sale report', () => h.q(`select staff_deco_sales(30)`));
  h.eq('art manager cannot see bot promotions', await err(`select * from staff_bot_promotions()`), 'Staff only');
  await h.admin();
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [art]);
  h.eq('mod_guard pass-through: art only', (await h.one(`select area_manager_may('deco_review') a, area_manager_may('badge') b, area_manager_may('bot_promo') c`)), { a: true, b: true, c: false });
  await h.as(art);
  await h.ok('art manager sees flagged decos', () => h.q(`select * from staff_flagged_decos()`));
  await h.ok('art manager rejects a deco', () => h.q(`select review_community_deco($1, 'rejected', 'blurry')`, [deco2]));
  h.eq('art manager reads art applications', (await h.q(`select area from area_applications_list()`)).length, 0);
  await h.as(mod);
  await h.ok('mods unchanged', () => h.q(`select staff_flagged_decos()`));

  // Only site admins touch the roles in the app: not the Artists server owner, who has every permission there.
  await h.as(artOwner);
  h.eq('owner cannot rename Art Manager', await err(`update roles set name = 'mine' where id = area_role_id('art')`), 'This role follows the Yapin\' staff list. Ask an admin');
  h.eq('owner cannot hand it out', await err(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, area_role_id('art'))`, [ART, artOwner]), 'This role follows the Yapin\' staff list. Ask an admin');
  h.eq('owner cannot take it off', await err(`delete from member_roles where user_id = $1 and role_id = area_role_id('art')`, [art]), 'This role follows the Yapin\' staff list. Ask an admin');
  h.eq('owner edits other roles', (await h.q(`update roles set color = '#123456' where server_id = $1 and name = 'Verified Artists' returning id`, [ART])).length, 1);
  // A Levels reward or a reaction role runs as definer under yapper.bot: still no way to hand the fixed role out.
  await h.admin();
  await h.db.exec(`create or replace function public.probe_give_role(sid uuid, uid uuid, rid uuid) returns void language plpgsql security definer set search_path = public as $$
    begin perform set_config('yapper.bot', '1', true);
      insert into public.member_roles (server_id, user_id, role_id, manual) values (sid, uid, rid, true) on conflict do nothing;
      perform set_config('yapper.bot', '', true); end $$;`);
  await h.as(artOwner);
  h.eq('owner cannot hand it out through a bot path', await err(`select probe_give_role($1, $2, area_role_id('art'))`, [ART, artOwner]), 'This role follows the Yapin\' staff list. Ask an admin');
  await h.ok('bot paths still give ordinary roles', () => h.q(`select probe_give_role($1, $2, (select id from roles where server_id = $1 and name = 'Verified Artists'))`, [ART, artOwner]));
  await h.admin();
  h.eq('role untouched', (await h.one(`select name from roles where id = area_role_id('art')`)).name, 'Art Manager');
  h.eq('assignment untouched', await held(art, 'art'), true);

  // Taking the role off: assignment gone, logged as before; the role itself stays for the next one.
  await h.as(admin);
  await h.ok('admin takes Art Manager off', () => h.q(`select admin_set_area_manager($1, 'art', false, 'done')`, [art]));
  await h.admin();
  h.eq('removed: role gone', await held(art, 'art'), false);
  h.eq('removed: badge gone', (await h.one(`select 'art_manager' = any(coalesce(badges, '{}')) b from profiles where id = $1`, [art])).b, false);
  h.eq('removed: still a member', (await h.one(`select exists (select 1 from server_members where server_id = $1 and user_id = $2) m`, [ART, art])).m, true);
  h.eq('the role itself stays', (await h.one(`select count(*)::int n from roles where id = area_role_id('art')`)).n, 1);
  // Someone deletes the role: the next add makes it again, in the same place.
  await h.q(`delete from roles where id = area_role_id('dev')`);
  await h.as(admin);
  await h.ok('admin makes a Dev Manager again', () => h.q(`select admin_set_area_manager($1, 'dev', false), admin_set_area_manager($1, 'dev', true)`, [dev]));
  await h.admin();
  h.eq('role remade', await order(DEV), ['Staff', 'Moderator', 'Dev Manager', 'Verified Developer', 'Developer']);
  h.eq('and given', await held(dev, 'dev'), true);
  await h.as(null);
  await h.fails('anon cannot ask the desk', `select my_area_desk()`);
}
