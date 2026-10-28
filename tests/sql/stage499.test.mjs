// 499: the permission helpers move from `language sql` to plpgsql (same bodies) so their plans are cached.
// Starts from stage 24 with stand-ins for the tables and the helpers 499 does not touch (channel_perm_of,
// channel_perm, channel_allows, staff_peek_ok, basic_perm, legacy_*, is_blocked_between).
// The OLD sql versions are rebuilt from 499 itself (the plpgsql wrapper taken off again), which gives back the live
// text of 25 Oct word for word: the live check compared each live body with the one inside 499.
// Then: every helper's answer for every user and input is stored, 499 is applied twice, and the answers, grants,
// owner, volatility, security definer and search_path must all be unchanged.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '499_plpgsql_helpers.sql'), 'utf8');

const NAMES = ['auto_role_applies', 'can_access_channel', 'can_post_channel', 'channel_access_server', 'channel_history_ok',
  'channel_overrides_live', 'channel_view_base', 'dm_blocked', 'feature_on', 'is_channel_member', 'is_server_member',
  'is_site_admin', 'is_site_banned', 'is_site_mod', 'is_staff', 'my_server_ids', 'server_perm', 'staff_mfa_ok'];
const SERVICE_ONLY = ['auto_role_applies', 'channel_overrides_live', 'is_site_banned'];

// 499 back to the sql functions it replaces.
const OLD = MIG.split('\n').filter((l) => !l.startsWith('--')).join('\n')
  .replace(/ language plpgsql\n/g, ' language sql\n')
  .replace(/#variable_conflict use_column\nbegin\n  return \(\n([\s\S]*?)\n  \);\nend;\n/g, '$1;\n')
  .replace(/#variable_conflict use_column\nbegin\n  return query\n([\s\S]*?);\nend;\n/g, '$1;\n');

// md5(prosrc) of the live sql versions, 25 Oct (before 499). The rebuilt OLD text must hash the same, so 499
// holds the live bodies word for word and nothing else.
const LIVE_MD5 = { "auto_role_applies": "1bea69482b8b0e8f3f45cd836f3bd193", "can_access_channel": "72154435cefca4d30c423277c7efba6b", "can_post_channel": "74de7d588ac9c62996fbfdd0e34a998e", "channel_access_server": "306b5785900b53dfa38766cc9ae44840", "channel_history_ok": "3088d30f372ca60357a587e985e83c03", "channel_overrides_live": "bd927417de2bbf9ed5e2f5e675c18fef", "channel_view_base": "ea73f7c4d922aef0c8b1a26845232d5c", "dm_blocked": "3f86dd45f029aecc155eca6f0045e6fc", "feature_on": "82cca9a1f34ea79a6e1c43ba06616ea0", "is_channel_member": "0bb9a1b849269525ff3c92fd7adabb57", "is_server_member": "62bb83047b5f38e5d5bc7780a317f09c", "is_site_admin": "603af85621fb87fd9d0fe91e5bac3814", "is_site_banned": "e32aece65e822423069d2884a477ec49", "is_site_mod": "cbb780370d51c901861288f2dad1cff9", "is_staff": "2bc9d129e1384d0577ce96495621d572", "my_server_ids": "87f90b53dd455c583ea86f2b97821636", "server_perm": "c2d88b35c8716409392baac26ef85fd1", "staff_mfa_ok": "b52c63ab122aaa4f5f9e118139f38dba" };

const STANDINS = String.raw`
set check_function_bodies = off;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
grant execute on function auth.jwt() to anon, authenticated, service_role;
alter table public.channels add column if not exists server_id uuid;
alter table public.channels add column if not exists category_id uuid;
alter table public.channels add column if not exists private boolean not null default false;
alter table public.channels add column if not exists read_only boolean not null default false;
alter table public.channels add column if not exists ticket_by uuid;
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.servers add column if not exists everyone_perms jsonb not null default '{}';
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists auto text;
alter table public.roles add column if not exists auto_before timestamptz;
alter table public.member_roles add column if not exists server_id uuid;
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), channel_id uuid, category_id uuid, allow boolean);
create table if not exists public.feature_flags (key text primary key, mode text, servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.t499_blocks (a uuid, b uuid);
create or replace function public.staff_peek_ok(sid uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.servers where id = sid and name like 'peek%') $$;
create or replace function public.basic_perm(perm text) returns boolean language sql immutable as $$
  select perm in ('send_messages', 'read_history', 'view_channel', 'connect', 'add_reactions') $$;
create or replace function public.legacy_manage_server(perm text) returns boolean language sql immutable as $$
  select perm in ('manage_server', 'manage_channels', 'manage_roles', 'kick_members', 'ban_members') $$;
create or replace function public.legacy_manage_messages(perm text) returns boolean language sql immutable as $$
  select perm = 'manage_messages' $$;
create or replace function public.is_blocked_between(x uuid, y uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.t499_blocks where (a = x and b = y) or (a = y and b = x)) $$;
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((select o.allow from public.channel_overrides o where o.channel_id = cid limit 1), base);
end $$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return public.channel_perm_of(auth.uid(), cid, perm, public.server_perm((select server_id from public.channels where id = cid), perm));
end $$;
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if public.channel_overrides_live(cid) then return public.channel_perm(cid, perm); end if;
  return public.server_perm((select server_id from public.channels where id = cid), perm);
end $$;
`;

const GRANTS = NAMES.map((n) => {
  const sig = `public.${n}`;
  return `do $g$ declare r regprocedure; begin
    for r in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '${n}' loop
      execute format('revoke all on function %s from public, anon, authenticated, service_role', r);
      execute format('grant execute on function %s to ${SERVICE_ONLY.includes(n) ? 'service_role' : 'authenticated, service_role'}', r);
    end loop; end $g$;`;
}).join('\n');

// Every helper, for every user (aal1 and aal2), over every server / channel / role / flag / perm.
const SNAPSHOT = (tag) => String.raw`
do $s$
declare u uuid; aal text;
begin
  for u in select id from auth.users loop
    foreach aal in array array['aal1', 'aal2'] loop
      perform set_config('request.jwt.claim.sub', u::text, false);
      perform set_config('request.jwt.claims', json_build_object('sub', u, 'aal', aal)::text, false);
      insert into t499_res select '${tag}', u, aal, 'is_staff', null, public.is_staff()::text
        union all select '${tag}', u, aal, 'is_site_admin', null, public.is_site_admin()::text
        union all select '${tag}', u, aal, 'is_site_mod', null, public.is_site_mod()::text
        union all select '${tag}', u, aal, 'staff_mfa_ok', null, public.staff_mfa_ok()::text
        union all select '${tag}', u, aal, 'my_server_ids', null, (select array_agg(x order by x)::text from public.my_server_ids() x)
        union all select '${tag}', u, aal, 'is_site_banned', v.id::text, public.is_site_banned(v.id)::text from auth.users v
        union all select '${tag}', u, aal, 'auto_role_applies', r.id::text, public.auto_role_applies(r.id, u)::text from public.roles r
        union all select '${tag}', u, aal, 'auto_role_applies_null', r.id::text, public.auto_role_applies(r.id, null)::text from public.roles r
        union all select '${tag}', u, aal, 'is_server_member', s.id::text, public.is_server_member(s.id)::text from public.servers s
        union all select '${tag}', u, aal, 'server_perm', s.id || '/' || p, public.server_perm(s.id, p)::text
          from public.servers s cross join unnest(array['manage_server', 'send_messages', 'read_history', 'view_channel', 'connect', 'kick_members', 'manage_messages', 'ban_members', 'odd']) p
        union all select '${tag}', u, aal, 'server_perm_null', p, public.server_perm(null, p)::text from unnest(array['send_messages', 'manage_server']) p
        union all select '${tag}', u, aal, 'feature_on', f.key || '/' || coalesce(s.id::text, '-'), public.feature_on(f.key, s.id)::text
          from (select key from public.feature_flags union all select 'missing') f cross join (select id from public.servers union all select null) s
        union all select '${tag}', u, aal, fn, c.id::text,
          case fn when 'can_access_channel' then public.can_access_channel(c.id)::text
                  when 'channel_access_server' then public.channel_access_server(c.id)
                  when 'channel_view_base' then public.channel_view_base(c.id)::text
                  when 'channel_history_ok' then public.channel_history_ok(c.id)::text
                  when 'can_post_channel' then public.can_post_channel(c.id)::text
                  when 'channel_overrides_live' then public.channel_overrides_live(c.id)::text
                  when 'is_channel_member' then public.is_channel_member(c.id)::text
                  when 'dm_blocked' then public.dm_blocked(c.id)::text end
          from (select id from public.channels union all select '00000000-0000-4000-8000-0000000000ff'::uuid) c
          cross join unnest(array['can_access_channel', 'channel_access_server', 'channel_view_base', 'channel_history_ok', 'can_post_channel',
                                  'channel_overrides_live', 'is_channel_member', 'dm_blocked']) fn;
    end loop;
  end loop;
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', '', false);
end $s$;`;

const META = `select p.proname, l.lanname, p.provolatile, p.prosecdef, p.proconfig::text, p.proacl::text, p.proowner::int, p.proisstrict,
  p.proleakproof, p.proparallel, p.procost::float, p.prorows::float, p.proretset, p.prorettype::int, p.proargtypes::text, p.proargnames::text
  from pg_proc p join pg_language l on l.oid = p.prolang where p.pronamespace = 'public'::regnamespace and p.proname = any($1) order by 1, p.oid`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(OLD);
  await h.db.exec(GRANTS);
  await h.db.exec(`set check_function_bodies = on;`);

  // The rebuilt old versions really are sql
  const before = await h.q(META, [NAMES]);
  h.eq('18 helpers, one each', before.length, 18);
  h.eq('all sql before 499', before.filter((r) => r.lanname !== 'sql').map((r) => r.proname), []);
  const md5 = Object.fromEntries((await h.q(`select proname, md5(prosrc) m from pg_proc where pronamespace = 'public'::regnamespace and proname = any($1)`, [NAMES])).map((r) => [r.proname, r.m]));
  h.eq('rebuilt old bodies are the live text', NAMES.filter((n) => md5[n] !== LIVE_MD5[n]), []);

  // Seed: 8 users, 4 servers, roles of every kind, channels of every kind
  const U = [];
  for (let i = 0; i < 8; i++) U.push(await h.signup(`u${i}@t.dev`, `user${i}`));
  const [owner, admin, mod, member, rolled, auto, banned, outsider] = U;
  const S = [];
  for (const [i, name] of ['main', 'peek-me', 'shut', 'quiet'].entries()) {
    S.push((await h.q(`insert into servers (name, owner_id) values ($1, $2) returning id`, [name, owner]))[0].id);
  }
  await h.q(`update servers set shut_down_at = now() where id = $1`, [S[2]]);
  await h.q(`update servers set everyone_perms = '{"send_messages": false, "read_history": false}' where id = $1`, [S[3]]);
  for (const s of S) for (const u of [owner, member, rolled, auto, banned, mod]) {
    await h.q(`insert into server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '10 days') on conflict do nothing`, [s, u]);
  }
  await h.q(`update server_members set joined_at = now() where user_id = $1 and server_id = $2`, [auto, S[1]]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2)`, [mod, member]);
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [member]);
  await h.q(`insert into site_bans (user_id) values ($1)`, [banned]);
  await h.q(`insert into site_bans (user_id, expires_at) values ($1, now() - interval '1 day') on conflict do nothing`, [outsider]);
  const role = async (s, name, extra) => (await h.q(`insert into roles (server_id, name, perms, manage_server, manage_messages, auto, auto_before)
    values ($1, $2, $3::jsonb, $4, $5, $6, $7) returning id`, [s, name, JSON.stringify(extra.perms ?? {}), extra.ms ?? false, extra.mm ?? false, extra.auto ?? null, extra.before ?? null]))[0].id;
  const R = {};
  for (const [i, s] of S.entries()) {
    R[`adm${i}`] = await role(s, 'Admin', { perms: { administrator: true } });
    R[`mgr${i}`] = await role(s, 'Mgr', { ms: true });
    R[`msg${i}`] = await role(s, 'Msgs', { mm: true, perms: { send_messages: true } });
    R[`all${i}`] = await role(s, 'Everyone auto', { auto: 'all', perms: { connect: true } });
    R[`bef${i}`] = await role(s, 'Old timers', { auto: 'before', before: new Date(Date.now() - 86400e3).toISOString() });
    R[`nob${i}`] = await role(s, 'Broken auto', { auto: 'before' });
    await h.q(`insert into member_roles (role_id, user_id, server_id) values ($1, $2, $3), ($4, $2, $3)`, [R[`msg${i}`], rolled, s, R[`mgr${i}`]]);
    if (i === 0) await h.q(`insert into member_roles (role_id, user_id, server_id) values ($1, $2, $3)`, [R.adm0, member, s]);
  }
  const ch = async (s, name, extra = {}) => (await h.q(`insert into channels (server_id, name, kind, private, read_only, category_id, ticket_by, dm_key)
    values ($1, $2, $3, $4, $5, $6, $7, $8) returning id`, [s, name, extra.kind ?? 'text', extra.priv ?? false, extra.ro ?? false, extra.cat ?? null, extra.ticket ?? null, extra.kind === 'dm' ? name : null]))[0].id;
  const cat = '00000000-0000-4000-8000-000000000001';
  const C = [];
  for (const [i, s] of S.entries()) {
    C.push(await ch(s, `general${i}`));
    const priv = await ch(s, `private${i}`, { priv: true }); C.push(priv);
    await h.q(`insert into channel_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [priv, R[`msg${i}`], s]);
    const privAuto = await ch(s, `oldtimers${i}`, { priv: true }); C.push(privAuto);
    await h.q(`insert into channel_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [privAuto, R[`bef${i}`], s]);
    const ticket = await ch(s, `ticket${i}`, { priv: true, ticket: member }); C.push(ticket);
    await h.q(`insert into channel_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [ticket, R[`mgr${i}`], s]);
    const ro = await ch(s, `news${i}`, { ro: true }); C.push(ro);
    await h.q(`insert into channel_post_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [ro, R[`all${i}`], s]);
    const ro2 = await ch(s, `rules${i}`, { ro: true }); C.push(ro2);
    await h.q(`insert into channel_post_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [ro2, R[`msg${i}`], s]);
    C.push(await ch(s, `voice${i}`, { kind: 'voice' }));
    const ov = await ch(s, `overridden${i}`, { cat }); C.push(ov);
    await h.q(`insert into channel_overrides (channel_id, allow) values ($1, $2)`, [ov, i % 2 === 0]);
    C.push(await ch(s, `incat${i}`, { cat, priv: true }));
    C.push(await ch(s, `voiceov${i}`, { kind: 'voice', cat }));
  }
  await h.q(`insert into channel_overrides (category_id, allow) values ($1, null)`, [cat]);
  const dm1 = await ch(null, 'dm1', { kind: 'dm' });
  const dm2 = await ch(null, 'dm2', { kind: 'dm' });
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3), ($4, $2), ($4, $5)`, [dm1, member, outsider, dm2, banned]);
  await h.q(`insert into t499_blocks values ($1, $2)`, [outsider, member]);
  await h.q(`insert into feature_flags (key, mode, servers, users) values
    ('channel_perms', 'test', array[$1, $2]::uuid[], '{}'), ('voice_chat', 'test', array[$1]::uuid[], array[$3]::uuid[]),
    ('staff_2fa', 'test', '{}', array[$4]::uuid[]), ('everyone_on', 'everyone', '{}', '{}'), ('off', 'off', '{}', '{}')`, [S[0], S[1], member, mod]);

  await h.q(`create table t499_res (tag text, uid uuid, aal text, fn text, arg text, v text)`);
  await h.db.exec(SNAPSHOT('old'));
  const n = Number((await h.q(`select count(*) n from t499_res`))[0].n);
  const trues = Number((await h.q(`select count(*) n from t499_res where v = 'true'`))[0].n);
  h.eq(`a real spread of answers (${n} total, ${trues} true)`, n > 5000 && trues > 1500 && n - trues > 1500, true);

  // Messages a user can read go through can_access_channel inside RLS
  // (triggers off for the seed: the new-account rate limit would stop the second message)
  await h.db.exec(`set session_replication_role = replica`);
  await h.q(`insert into messages (channel_id, author_id, content) select c, $1, 'hi' from unnest($2::uuid[]) c`, [owner, [...C, dm1, dm2]]);
  await h.db.exec(`set session_replication_role = origin`);
  const seen = async () => { const out = []; for (const u of U) { await h.as(u); out.push(Number((await h.q(`select count(*) n from messages`))[0].n)); } await h.admin(); return out; };
  const seenBefore = await seen();

  await h.ok('499 applies', () => h.db.exec(MIG));
  await h.ok('499 re-runs cleanly', () => h.db.exec(MIG));

  const after = await h.q(META, [NAMES]);
  h.eq('still 18 helpers, no new overloads', after.length, 18);
  h.eq('all plpgsql now', after.filter((r) => r.lanname !== 'plpgsql').map((r) => r.proname), []);
  const strip = (rows) => rows.map(({ lanname, ...r }) => r);
  h.eq('grants, owner, volatility, definer, search_path, args, rows unchanged', strip(after), strip(before));
  h.eq('stable security definer, search_path=public', after.every((r) => r.provolatile === 's' && r.prosecdef && r.proconfig === '{search_path=public}'), true);

  await h.db.exec(SNAPSHOT('new'));
  const diff = await h.q(`select o.fn, o.arg, o.uid, o.aal, o.v old, n.v new from t499_res o
    left join t499_res n on n.tag = 'new' and n.uid = o.uid and n.aal = o.aal and n.fn = o.fn and n.arg is not distinct from o.arg
    where o.tag = 'old' and (n.tag is null or n.v is distinct from o.v) limit 5`);
  h.eq('every answer the same after 499', diff, []);
  h.eq('same number of answers', Number((await h.q(`select count(*) n from t499_res where tag = 'new'`))[0].n), n);
  h.eq('RLS on messages sees the same rows', await seen(), seenBefore);

  // Grants still work as before
  const call = async (who, sql) => { await h.as(who); try { return Object.values((await h.q(sql))[0])[0]; } catch (e) { return e.message; } finally { await h.admin(); } };
  h.eq('members still call can_access_channel', await call(member, `select can_access_channel('${C[0]}')`), true);
  h.eq('members still call server_perm', await call(rolled, `select server_perm('${S[0]}', 'manage_messages')`), true);
  h.eq('is_site_banned still service-only', String(await call(member, `select is_site_banned('${banned}')`)).includes('permission denied'), true);
  h.eq('auto_role_applies still service-only', String(await call(member, `select auto_role_applies('${R.all0}', '${member}')`)).includes('permission denied'), true);
  h.eq('anon still refused', String(await call(null, `select is_server_member('${S[0]}')`)).includes('permission denied'), true);
  h.eq('my_server_ids as a member', Number(await call(member, `select count(*) from my_server_ids()`)), 4);
  h.eq('banned member: no channel', await call(banned, `select can_access_channel('${C[0]}')`), false);
}
