// 316: database load cuts. bootstrap_fast can't run in PGlite (it reads most of the live schema), so its body only
// loads here; its role-assignment part is the same SQL as server_role_assignments, which is checked below.
// Checked: role assignments in one call, member search by prefix (both the small-server and the big-server path),
// exact username lookups, the unread notices the message trigger sends, flags and who may call what.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '316_db_load_cuts.sql'), 'utf8');

const STANDINS = `
alter table public.roles add column if not exists auto text default 'none';
alter table public.roles add column if not exists auto_before timestamptz;
alter table public.member_roles add column if not exists manual boolean not null default false;
alter table public.profiles add column if not exists display_name text;
alter table public.channels add column if not exists private boolean not null default false;
alter table public.channels add column if not exists category_id uuid;
alter table public.messages add column if not exists reply_to_id uuid;
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), channel_id uuid, category_id uuid);
create table if not exists public.app_settings (id int);
alter table public.app_settings add column if not exists rt_mode text;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.can_access_channel(cid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (auth.uid() = any(users) or exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers)))) from public.feature_flags where key = k), false);
$$;
create table if not exists public.sent (topic text, event text, payload jsonb);
`;
// After 316: record what would go to the realtime server.
const RECORD = `
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
  returns void language plpgsql security definer set search_path = public as $$
begin insert into public.sent values (topic_name, event_name, jsonb_build_object('operation', operation)); end $$;
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb)
  returns void language sql security definer set search_path = public as $$
  insert into public.sent values (topic_name, event_name, payload);
$$;
alter table public.messages disable trigger messages_raid_guard;
drop trigger if exists messages_broadcast on public.messages;
create trigger messages_broadcast after insert or update or delete on public.messages for each row execute function public.broadcast_message_change();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(`set check_function_bodies = off;`);
  await h.db.exec(MIG);
  await h.ok('316 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`set check_function_bodies = on;`);
  await h.db.exec(RECORD);

  // ---------- who may call what ----------
  const can = async (role, fn) => (await h.one(`select has_function_privilege($1, 'public.${fn}', 'execute') ok`, [role])).ok;
  for (const fn of ['server_role_assignments(uuid[])', 'find_server_members(uuid, text, boolean, integer)', 'user_id_by_username(text)']) {
    h.eq(`signed-in people can call ${fn}`, await can('authenticated', fn), true);
    h.eq(`logged-out people can't call ${fn}`, await can('anon', fn), false);
  }
  h.eq(`nobody signed in can call bc_notice`, [await can('anon', 'bc_notice(text, text, jsonb)'), await can('authenticated', 'bc_notice(text, text, jsonb)')], [false, false]);
  h.eq(`bootstrap_fast stays internal`, [await can('anon', 'bootstrap_fast()'), await can('authenticated', 'bootstrap_fast()')], [false, false]);
  const flags = await h.q(`select key, mode from feature_flags where key in ('live_badges', 'lazy_boot', 'member_search_names') order by key`);
  h.eq('three flags, all in test mode', flags.map((f) => `${f.key}=${f.mode}`), ['lazy_boot=test', 'live_badges=test', 'member_search_names=test']);

  // ---------- people and a server ----------
  const amy = await h.signup('amy@test.dev', 'Amy_One');
  const bob = await h.signup('bob@test.dev', 'bobby');
  const cat = await h.signup('cat@test.dev', 'cat');
  const dan = await h.signup('dan@test.dev', 'AmyXOne');
  await h.admin();
  await h.q(`update profiles set display_name = 'Zed Amy' where id = $1`, [bob]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('O', $1) returning id`, [cat])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4), ($5, $6) on conflict do nothing`, [sid, amy, bob, dan, other, cat]);

  // ---------- server_role_assignments ----------
  const mod = (await h.one(`insert into roles (server_id, name, auto) values ($1, 'mod', 'none') returning id`, [sid])).id;
  const nul = (await h.one(`insert into roles (server_id, name, auto) values ($1, 'old', null) returning id`, [sid])).id;
  const og = (await h.one(`insert into roles (server_id, name, auto) values ($1, 'og', 'before') returning id`, [sid])).id;
  const all = (await h.one(`insert into roles (server_id, name, auto) values ($1, 'all', 'all') returning id`, [sid])).id;
  const theirs = (await h.one(`insert into roles (server_id, name) values ($1, 'theirs') returning id`, [other])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id, manual) values
    ($1, $2, $4, false), ($1, $3, $5, false), ($1, $2, $6, false), ($1, $3, $6, true), ($1, $2, $7, false), ($8, $9, $10, false)`,
    [sid, amy, bob, mod, nul, og, all, other, cat, theirs]);
  const roleRows = async (who, sids) => {
    await h.as(who);
    const r = (await h.one(`select server_role_assignments($1::uuid[]) a`, [sids])).a;
    return r.map((x) => `${x[1] === amy ? 'amy' : x[1] === bob ? 'bob' : 'cat'}:${x[2] === mod ? 'mod' : x[2] === nul ? 'old' : x[2] === og ? 'og' : x[2] === all ? 'all' : 'theirs'}`).sort();
  };
  h.eq('non-automatic roles, plus automatic ones given by hand; not other servers', await roleRows(amy, [sid, other]), ['amy:mod', 'bob:og', 'bob:old']);
  h.eq('a server I am not in tells me nothing', await roleRows(cat, [sid]), []);
  h.eq('a member of the other server sees only it', await roleRows(cat, [sid, other]), ['cat:theirs']);

  // ---------- find_server_members ----------
  const find = async (who, q, names = false, server = sid) => {
    await h.as(who);
    return (await h.q(`select user_id from find_server_members($1, $2, $3)`, [server, q, names])).map((r) => r.user_id === amy ? 'amy' : r.user_id === bob ? 'bob' : r.user_id === dan ? 'dan' : r.user_id);
  };
  h.eq('prefix, any case', await find(bob, 'AMY'), ['amy', 'dan']);
  h.eq('_ is a plain character', await find(bob, 'amy_'), ['amy']);
  h.eq('% is a plain character', await find(bob, 'a%'), []);
  h.eq('middle of a name does not match (prefix like Discord)', await find(bob, 'one'), []);
  h.eq('display names only with with_display', [await find(amy, 'zed'), await find(amy, 'zed', true)], [[], ['bob']]);
  h.eq('one character is too short', await find(amy, 'a'), []);
  h.eq('not a member: nothing', await find(cat, 'amy'), []);
  h.eq('members of other servers are not found', await find(amy, 'cat'), []);

  // Big server: more than 2000 members takes the profile index path.
  await h.admin();
  await h.db.exec(`insert into auth.users (email, raw_user_meta_data) select 'u' || g || '@t.dev', jsonb_build_object('username', 'filler' || g) from generate_series(1, 2020) g`);
  await h.q(`insert into server_members (server_id, user_id) select $1, id from profiles where username like 'filler%' on conflict do nothing`, [sid]);
  await h.q(`update profiles set display_name = 'Amy Fan' where username = 'filler7'`);
  h.eq('big server: same answers', [await find(bob, 'AMY'), await find(bob, 'amy_'), await find(cat, 'amy')], [['amy', 'dan'], ['amy'], []]);
  h.eq('big server: display names', (await find(bob, 'amy f', true)).length, 1);
  h.eq('big server: at most 10 by default', (await find(bob, 'filler')).length, 10);
  await h.as(bob);
  h.eq('big server: sorted by username', (await h.q(`select p.username from find_server_members($1, 'filler1', false, 3) f join profiles p on p.id = f.user_id`, [sid])).map((r) => r.username), ['filler1', 'filler10', 'filler100']);

  // ---------- user_id_by_username ----------
  await h.as(cat);
  const byName = async (n) => (await h.one(`select user_id_by_username($1) id`, [n])).id;
  h.eq('exact, any case', [await byName('amy_one'), await byName(' AMY_ONE ')], [amy, amy]);
  h.eq('_ is not a wildcard', await byName('amyxone'), dan);
  h.eq('no prefix matches', [await byName('amy'), await byName('amy%'), await byName('')], [null, null, null]);

  // ---------- unread notices ----------
  await h.admin();
  const open = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [sid])).id;
  const priv = (await h.one(`insert into channels (server_id, name, kind, private) values ($1, 'staff', 'text', true) returning id`, [sid])).id;
  const cat1 = (await h.one(`select gen_random_uuid() id`)).id;
  const ovr = (await h.one(`insert into channels (server_id, name, kind, category_id) values ($1, 'ov', 'text', $2) returning id`, [sid, cat1])).id;
  await h.q(`insert into channel_overrides (category_id) values ($1)`, [cat1]);
  const dm = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'a:b') returning id`)).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, amy, bob]);
  await h.q(`update app_settings set rt_mode = 'vps'`);
  await h.q(`insert into app_settings (rt_mode) select 'vps' where not exists (select 1 from app_settings)`);
  const notices = async () => (await h.q(`select topic, payload from sent where event = 'unread' order by ctid`)).map((r) => r);
  const send = async (cid, content) => { await h.q(`delete from sent`); return (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, $3) returning id`, [cid, amy, content])).id; };

  await send(open, 'before the flag');
  h.eq('a server without the flag sends no notices', (await notices()).length, 0);
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'live_badges'`, [sid]);
  const m1 = await send(open, 'hi');
  let n = await notices();
  h.eq('open channel: one notice on the server topic, no content', [n.length, n[0].topic, n[0].payload.channel_id, n[0].payload.id, n[0].payload.author_id, n[0].payload.restricted, n[0].payload.everyone, n[0].payload.operation, 'content' in n[0].payload],
    [1, `server:${sid}`, open, m1, amy, false, false, 'INSERT', false]);
  h.eq('the channel topic still gets the message', (await h.q(`select 1 from sent where topic = $1 and event = 'message'`, [`chan:${open}`])).length, 1);
  await send(open, 'hey @everyone look');
  h.eq('@everyone is marked', (await notices())[0].payload.everyone, true);
  await send(open, 'mail@everyone.com');
  h.eq('an email address is not @everyone', (await notices())[0].payload.everyone, false);
  await send(open, '↪ Forwarded\n@everyone');
  h.eq('a forwarded @everyone is not a ping', (await notices())[0].payload.everyone, false);
  await send(priv, 'secret');
  h.eq('private channel: marked restricted', (await notices())[0].payload.restricted, true);
  await send(ovr, 'x');
  h.eq('category override: marked restricted', (await notices())[0].payload.restricted, true);
  await send(dm, 'psst');
  h.eq('DMs send no server notice', (await notices()).length, 0);
  await h.q(`delete from sent`);
  await h.q(`update messages set content = 'edited' where id = $1`, [m1]);
  h.eq('edits send no notice', (await notices()).length, 0);
  await h.q(`delete from messages where id = $1`, [m1]);
  n = await notices();
  h.eq('deletes send one', [n.length, n[0]?.payload.operation, n[0]?.payload.id, n[0]?.payload.everyone], [1, 'DELETE', m1, false]);
  await h.q(`update app_settings set rt_mode = 'supabase'`);
  await h.db.exec(`create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language plpgsql security definer set search_path = public as $f$ begin end $f$;`);
  await h.db.exec(MIG.slice(MIG.indexOf('create or replace function public.bc_notice'), MIG.indexOf('revoke execute on function public.bc_notice')));
  await h.q(`delete from sent`);
  await send(open, 'quiet');
  h.eq('rt_mode supabase: bc_notice sends nothing', (await notices()).length, 0);
}
