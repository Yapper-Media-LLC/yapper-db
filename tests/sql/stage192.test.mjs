// 192: voice mutes per server, staff site-wide voice mutes, voice bans (flag voice_ban).
// PGlite can't replay every migration, so like stage157 this starts from stage 24 (+ flags 031/041), adds small
// stand-ins for the live pieces 192 leans on (server_perm with role perms, outranks, staff, Logger), then the live
// definitions of voice_ticket and voice_timeout copied verbatim from the live database (read-only, Oct 17), so the
// in-place voice_ticket patch is checked against the real text. Then 192 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists voice_muted_until timestamptz;
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists category_id uuid;
alter table public.app_settings add column if not exists new_account_wait interval;
create table if not exists public.server_timeouts (server_id uuid, user_id uuid, until timestamptz);
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.test_log (kind text, server_id uuid, body text, at timestamptz default clock_timestamp());
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$$;
-- Owner, Administrator, a role with the perm, or Connect / Speak for any member (@everyone).
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or (perm in ('connect', 'speak') and exists (select 1 from public.server_members where server_id = sid and user_id = auth.uid()))
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create or replace function public.outranks(sid uuid, target uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or (target <> (select owner_id from public.servers where id = sid)
        and coalesce((select max(r.position) from public.member_roles mr join public.roles r on r.id = mr.role_id where mr.server_id = sid and mr.user_id = auth.uid()), -1)
          > coalesce((select max(r.position) from public.member_roles mr join public.roles r on r.id = mr.role_id where mr.server_id = sid and mr.user_id = target), -1));
$$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql stable as $$ select true $$;
create or replace function public.auto_role_applies(rid uuid, uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.log_name(uid uuid) returns text language sql stable as $$ select coalesce((select username from public.profiles where id = uid), 'someone') $$;
create or replace function public.log_clean(t text, maxlen integer default 600) returns text language sql stable as $$ select left(coalesce(t, ''), maxlen) $$;
create or replace function public.bot_log_kind(kind text, sid uuid, body text) returns void language sql security definer set search_path = public as $$
  insert into public.test_log (kind, server_id, body) values (kind, sid, body)
$$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
const LIVE = `
CREATE OR REPLACE FUNCTION public.voice_ticket(cid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := auth.uid();
  ch record;
  p record;
  ban record;
  until_ts timestamptz;
  st record;
  wait_ms bigint;
  no_speak boolean := false;
begin
  if me is null then return jsonb_build_object('error', 'Not signed in'); end if;
  select user_id, expires_at into ban from public.site_bans where user_id = me;
  if found and (ban.expires_at is null or ban.expires_at > now()) then
    return jsonb_build_object('error', 'Your account is banned from Yapper');
  end if;
  select c.id, c.kind, c.server_id, (c.server_id is not null and exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)) as live
    into ch from public.channels c
   where c.id = cid and c.kind in ('voice', 'dm', 'group') and public.can_access_channel(c.id);
  if not found then return jsonb_build_object('error', 'You can’t join that call'); end if;
  if ch.live then
    if not public.channel_perm(ch.id, 'connect') then
      return jsonb_build_object('error', 'You don''t have permission to join this voice channel');
    end if;
    no_speak := not public.channel_perm(ch.id, 'speak');
  elsif ch.server_id is not null and not public.server_perm(ch.server_id, 'connect')
        and not exists (select 1 from public.roles r
                        where r.server_id = ch.server_id and coalesce((r.perms->>'connect')::boolean, false)
                          and public.auto_role_applies(r.id, me)) then
    return jsonb_build_object('error', 'You don''t have permission to join this voice channel');
  end if;
  select username, created_at, muted_until, voice_muted_until into p from public.profiles where id = me;
  if p.muted_until is not null and p.muted_until > now() then
    return jsonb_build_object('error', 'You’re timed out until ' || to_char(p.muted_until at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC.');
  end if;
  if ch.server_id is not null then
    select t.until into until_ts from public.server_timeouts t where t.server_id = ch.server_id and t.user_id = me and t.until > now();
    if until_ts is not null then
      return jsonb_build_object('error', 'You’re timed out in this server until ' || to_char(until_ts at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC.');
    end if;
    if exists (select 1 from public.server_bans b where b.server_id = ch.server_id and b.user_id = me) then
      return jsonb_build_object('error', 'You’re banned from this server');
    end if;
    select default_server_id, new_account_wait into st from public.app_settings limit 1;
    if st.default_server_id = ch.server_id and st.new_account_wait is not null and p.created_at > now() - st.new_account_wait then
      wait_ms := extract(epoch from st.new_account_wait) * 1000;
      return jsonb_build_object('error', 'Welcome! New accounts can join voice here ' || ceil(wait_ms / 60000.0)::int || ' minutes after signing up.');
    end if;
  end if;
  return jsonb_build_object('name', coalesce(p.username, 'someone'),
                            'voice_muted', no_speak or (p.voice_muted_until is not null and p.voice_muted_until > now()),
                            'no_speak', no_speak);
end $function$;

CREATE OR REPLACE FUNCTION public.voice_timeout(uid uuid, vchannel uuid, minutes integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid;
begin
  minutes := least(greatest(coalesce(minutes, 0), 0), 1440);
  select server_id into sid from public.channels where id = vchannel and kind = 'voice';
  if not public.is_staff() then
    if sid is null or not public.server_perm(sid, 'mute_members') then raise exception 'You need Mute Members to do that'; end if;
    if uid = auth.uid() then raise exception 'Not yourself'; end if;
    if not exists (select 1 from public.server_members where server_id = sid and user_id = uid) then raise exception 'They''re not in this server'; end if;
    if not public.outranks(sid, uid) then raise exception 'You can''t mute someone with a role as high as yours'; end if;
  end if;
  if public.is_staff_user(uid) then raise exception 'You can''t mute Yapper staff'; end if;
  update public.profiles set voice_muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end where id = uid;
end;
$function$;
`;

const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '192_voice_mutes_per_server.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(MIGRATION);
  await h.ok('192 re-runs cleanly', () => h.db.exec(MIGRATION));
  h.eq('voice_ticket patched once', (await h.one(`select (length(d) - length(replace(d, '192:', ''))) / 4 n from pg_get_functiondef('public.voice_ticket(uuid)'::regprocedure) d`)).n, 2);

  const owner = await h.signup('owner@test.dev', 'owner');
  const mod = await h.signup('mod@test.dev', 'mod');
  const peer = await h.signup('peer@test.dev', 'peer');
  const kid = await h.signup('kid@test.dev', 'kid');
  const staff = await h.signup('staff@test.dev', 'staff');
  const outsider = await h.signup('out@test.dev', 'outsider');
  await h.as(owner);
  const A = (await h.one(`select create_server('Server A', null) id`)).id;
  const B = (await h.one(`select create_server('Server B', null) id`)).id;
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  const voice = async (sid) => (await h.one(`insert into channels (kind, name, server_id, created_by) values ('voice', 'Voice', $1, $2) returning id`, [sid, owner])).id;
  const vA = await voice(A);
  const vA2 = await voice(A);
  const vB = await voice(B);
  for (const sid of [A, B]) {
    await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4), ($1, $5) on conflict do nothing`, [sid, mod, peer, kid, staff]);
    const role = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Mods', 5, '{"mute_members": true, "move_members": true}') returning id`, [sid])).id;
    await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3), ($1, $4, $3)`, [sid, mod, role, peer]);
  }
  const ticket = async (uid, cid) => { await h.as(uid); const t = (await h.one(`select voice_ticket($1) t`, [cid])).t; await h.admin(); return t; };
  const tryAs = async (uid, sql, params = []) => {
    await h.as(uid);
    try { await h.q(sql, params); return null; } catch (e) { return e.message; } finally { await h.admin(); }
  };

  // ---- A: mutes are per server ----
  h.eq('nobody muted at first', (await ticket(kid, vA)).voice_muted, false);
  h.eq('mod mutes kid in A', await tryAs(mod, `select voice_timeout($1, $2, 10)`, [kid, vA]), null);
  h.eq('kid is muted in A', (await ticket(kid, vA)).voice_muted, true);
  h.eq('kid is muted in the other voice channel of A too', (await ticket(kid, vA2)).voice_muted, true);
  h.eq('kid is NOT muted in B', (await ticket(kid, vB)).voice_muted, false);
  h.eq('the global column stays empty', (await h.one(`select voice_muted_until v from profiles where id = $1`, [kid])).v, null);
  h.eq('who muted is kept', (await h.one(`select by from server_voice_mutes where server_id = $1 and user_id = $2`, [A, kid])).by, mod);
  h.eq('capped at 1440 minutes', await tryAs(mod, `select voice_timeout($1, $2, 99999)`, [kid, vA]), null);
  h.eq('cap applied', (await h.one(`select until <= now() + interval '1440 minutes 1 second' ok from server_voice_mutes where server_id = $1 and user_id = $2`, [A, kid])).ok, true);
  h.eq('minutes 0 clears', await tryAs(mod, `select voice_timeout($1, $2, 0)`, [kid, vA]), null);
  h.eq('kid can talk in A again', (await ticket(kid, vA)).voice_muted, false);
  h.eq('an expired row does not mute', (await (async () => {
    await h.q(`insert into server_voice_mutes (server_id, user_id, until) values ($1, $2, now() - interval '1 minute')`, [A, kid]);
    return (await ticket(kid, vA)).voice_muted;
  })()), false);
  h.eq('mute checks: no Mute Members', (await tryAs(kid, `select voice_timeout($1, $2, 10)`, [peer, vA]))?.includes('Mute Members'), true);
  h.eq('mute checks: same rank', (await tryAs(mod, `select voice_timeout($1, $2, 10)`, [peer, vA]))?.includes('as high as yours'), true);
  h.eq('mute checks: staff target', (await tryAs(mod, `select voice_timeout($1, $2, 10)`, [staff, vA]))?.includes('Yapper staff'), true);
  h.eq('staff using a server channel mute that server only', await tryAs(staff, `select voice_timeout($1, $2, 10)`, [kid, vB]), null);
  h.eq('... muted in B', (await ticket(kid, vB)).voice_muted, true);
  h.eq('... not in A', (await ticket(kid, vA)).voice_muted, false);
  await h.as(staff); await h.q(`select voice_timeout($1, $2, 0)`, [kid, vB]); await h.admin();

  // ---- site-wide staff mute still works everywhere ----
  h.eq('a mod can\'t use the staff mute', (await tryAs(mod, `select staff_voice_timeout($1, 60)`, [kid]))?.includes('Staff only'), true);
  h.eq('staff mute site-wide', await tryAs(staff, `select staff_voice_timeout($1, 60)`, [kid]), null);
  h.eq('staff mute: muted in A', (await ticket(kid, vA)).voice_muted, true);
  h.eq('staff mute: muted in B', (await ticket(kid, vB)).voice_muted, true);
  h.eq('staff mute: not yourself', (await tryAs(staff, `select staff_voice_timeout($1, 60)`, [staff]))?.includes('Not yourself'), true);
  await h.as(staff); await h.q(`select staff_voice_timeout($1, 0)`, [kid]); await h.admin();
  h.eq('staff mute cleared', (await ticket(kid, vB)).voice_muted, false);
  // A global value set before 192 (by anyone) keeps working until it runs out.
  await h.q(`update profiles set voice_muted_until = now() + interval '5 minutes' where id = $1`, [kid]);
  h.eq('old global value still mutes', (await ticket(kid, vB)).voice_muted, true);
  await h.q(`update profiles set voice_muted_until = null where id = $1`, [kid]);

  // ---- voice bans ----
  h.eq('flag off for A at first: refused', (await tryAs(mod, `select voice_ban($1, $2, 60, 'loud')`, [A, kid]))?.includes('available'), true);
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'voice_ban'`, [A]);
  h.eq('flag row is in test mode', (await h.one(`select mode from feature_flags where key = 'voice_ban'`)).mode, 'test');
  h.eq('B is still off', (await tryAs(mod, `select voice_ban($1, $2, 60, 'loud')`, [B, kid]))?.includes('available'), true);
  h.eq('no Move Members', (await tryAs(kid, `select voice_ban($1, $2, 60, '')`, [A, outsider]))?.includes('Move Members'), true);
  h.eq('not yourself', (await tryAs(mod, `select voice_ban($1, $2, 60, '')`, [A, mod]))?.includes('Not yourself'), true);
  h.eq('same rank', (await tryAs(mod, `select voice_ban($1, $2, 60, '')`, [A, peer]))?.includes('as high as yours'), true);
  h.eq('not the owner', (await tryAs(mod, `select voice_ban($1, $2, 60, '')`, [A, owner])) !== null, true);
  h.eq('never staff', (await tryAs(owner, `select voice_ban($1, $2, 60, '')`, [A, staff]))?.includes('Yapper staff'), true);
  h.eq('must be a member', (await tryAs(owner, `select voice_ban($1, $2, 60, '')`, [A, outsider]))?.includes('not in this server'), true);
  h.eq('bad duration', (await tryAs(mod, `select voice_ban($1, $2, 0, '')`, [A, kid]))?.includes('how long'), true);
  h.eq('no direct writes', (await tryAs(mod, `insert into server_voice_bans (server_id, user_id) values ($1, $2)`, [A, kid])) !== null, true);

  h.eq('mod bans kid from A voice for an hour', await tryAs(mod, `select voice_ban($1, $2, 60, 'too loud')`, [A, kid]), null);
  const t1 = await ticket(kid, vA);
  h.eq('kid can\'t join A voice', t1.error?.startsWith('You’re banned from voice in this server until '), true);
  h.eq('... with the end time', /until \d{4}-\d\d-\d\d \d\d:\d\d UTC\.$/.test(t1.error ?? ''), true);
  h.eq('... nor the other A channel', (await ticket(kid, vA2)).error?.startsWith('You’re banned from voice'), true);
  h.eq('kid can still join B voice', (await ticket(kid, vB)).error, undefined);
  h.eq('Logger got the ban', (await h.one(`select body from test_log where server_id = $1 order by at desc limit 1`, [A])).body.includes('**kid** was banned from voice until'), true);
  h.eq('... with the reason', (await h.one(`select body from test_log where server_id = $1 order by at desc limit 1`, [A])).body.endsWith(': too loud'), true);

  // RLS: themselves and people with Move/Mute Members see it; others don't.
  const seen = async (uid) => { await h.as(uid); const r = await h.q(`select user_id from server_voice_bans where server_id = $1`, [A]); await h.admin(); return r.length; };
  h.eq('kid sees their own ban', await seen(kid), 1);
  h.eq('mod sees it', await seen(mod), 1);
  h.eq('owner sees it', await seen(owner), 1);
  h.eq('outsider sees nothing', await seen(outsider), 0);
  const seenMutes = async (uid) => { await h.as(uid); const r = await h.q(`select user_id from server_voice_mutes`); await h.admin(); return r.length; };
  h.eq('outsider sees no mutes', await seenMutes(outsider), 0);
  h.eq('no direct mute writes', (await tryAs(mod, `update server_voice_mutes set until = now()`)) !== null, true);

  // Forever, then expiry.
  h.eq('forever ban', await tryAs(owner, `select voice_ban($1, $2, null, '')`, [A, kid]), null);
  h.eq('forever message', (await ticket(kid, vA)).error, 'You’re banned from voice in this server');
  await h.q(`update server_voice_bans set until = now() - interval '1 minute' where server_id = $1 and user_id = $2`, [A, kid]);
  h.eq('an expired ban lets them back in', (await ticket(kid, vA)).error, undefined);
  h.eq('re-ban after expiry', await tryAs(mod, `select voice_ban($1, $2, 1440, '')`, [A, kid]), null);
  h.eq('banned again', (await ticket(kid, vA)).error?.startsWith('You’re banned from voice'), true);

  // Unban.
  h.eq('can\'t unban yourself', (await tryAs(kid, `select voice_unban($1, $2)`, [A, kid]))?.includes('Not yourself'), true);
  h.eq('unban by someone without Move Members', (await tryAs(outsider, `select voice_unban($1, $2)`, [A, kid]))?.includes('Move Members'), true);
  h.eq('mod unbans', await tryAs(mod, `select voice_unban($1, $2)`, [A, kid]), null);
  h.eq('kid can join A voice again', (await ticket(kid, vA)).error, undefined);
  h.eq('unban twice', (await tryAs(mod, `select voice_unban($1, $2)`, [A, kid]))?.includes('aren\'t banned'), true);
  h.eq('Logger got the unban', (await h.one(`select body from test_log where server_id = $1 order by at desc limit 1`, [A])).body.includes('unbanned from voice'), true);

  // Staff can voice ban anywhere the flag is on.
  h.eq('staff bans without a role', await tryAs(staff, `select voice_ban($1, $2, 60, '')`, [A, peer]), null);
  h.eq('peer banned', (await ticket(peer, vA)).error?.startsWith('You’re banned from voice'), true);

  // Flag off again: the RPCs refuse.
  await h.q(`update feature_flags set servers = '{}' where key = 'voice_ban'`);
  h.eq('flag off: ban refused', (await tryAs(owner, `select voice_ban($1, $2, 60, '')`, [A, kid]))?.includes('available'), true);
  h.eq('flag off: unban refused', (await tryAs(owner, `select voice_unban($1, $2)`, [A, peer]))?.includes('available'), true);
}
