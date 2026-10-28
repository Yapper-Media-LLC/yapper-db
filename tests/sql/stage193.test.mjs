// 193: raid protection, the new account rule per server (flag raid_protection).
// PGlite can't replay every migration, so like stage157/192 this starts from stage 24 (+ flags 031/041), adds small
// stand-ins for the live pieces 193 leans on (staff, server_perm with role perms, lock columns, Discovery), then the
// live definitions of join_server, join_public_server and message_raid_guard copied from the live database
// (read-only, Oct 17), so the in-place patches are checked against the real text. Then 193 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.servers add column if not exists locked_until timestamptz;
alter table public.servers add column if not exists lock_reason text;
alter table public.servers add column if not exists discoverable boolean not null default false;
alter table public.roles add column if not exists perms jsonb not null default '{}';
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$$;
-- Owner, Administrator, or a role with the perm.
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
const LIVE = String.raw`
CREATE OR REPLACE FUNCTION public.is_site_banned(uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$function$;
CREATE OR REPLACE FUNCTION public.join_server(invite_code text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid; staff boolean := public.is_staff();
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select server_id into sid from public.invites where lower(code) = lower(invite_code);
  if sid is null then raise exception 'This invite is invalid or has expired'; end if;
  if not staff and public.server_locked(sid) then raise exception 'This server is locked right now. Try again in a few minutes.'; end if;
  if not staff and exists (select 1 from public.server_bans where server_id = sid and user_id = auth.uid()) then
    raise exception 'You''re banned from this server';
  end if;
  if not staff and (select count(*) from public.server_members where user_id = auth.uid()) >= 100 then
    raise exception 'You''re in too many servers';
  end if;
  insert into public.server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  if found then
    update public.invites set uses = uses + 1 where lower(code) = lower(invite_code);
  end if;
  return sid;
end; $function$;
CREATE OR REPLACE FUNCTION public.join_public_server(sid uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare staff boolean := public.is_staff();
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if public.is_site_banned(auth.uid()) then raise exception 'That account is banned'; end if;
  if not staff and not (select discoverable from public.servers where id = sid) then raise exception 'That server isn''t public'; end if;
  if not staff and public.server_locked(sid) then raise exception 'This server is locked right now. Try again in a few minutes.'; end if;
  if not staff and exists (select 1 from public.server_bans b where b.server_id = sid and b.user_id = auth.uid()) then raise exception 'You''re banned from that server'; end if;
  if not staff and (select count(*) from public.server_members where user_id = auth.uid()) >= 100 then raise exception 'You''re in too many servers'; end if;
  insert into public.server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  return sid;
end; $function$;
CREATE OR REPLACE FUNCTION public.message_raid_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare joined timestamptz; wait interval; def uuid; last_at timestamptz; recent int;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  perform pg_advisory_xact_lock(hashtext('send:' || new.author_id::text));
  select count(*) into recent from public.messages
    where author_id = new.author_id and created_at > now() - interval '5 seconds' and id <> new.id;
  if recent >= 5 then
    raise exception 'You’re sending messages too fast. Wait a few seconds.' using errcode = 'check_violation';
  end if;
  select created_at into joined from public.profiles where id = new.author_id;
  select default_server_id, new_account_wait into def, wait from public.app_settings where id;
  if joined > now() - interval '1 hour' then
    select max(created_at) into last_at from public.messages where author_id = new.author_id and id <> new.id;
    if last_at > now() - interval '3 seconds' then
      raise exception 'Slow down a little. New accounts can send one message every 3 seconds' using errcode = 'check_violation';
    end if;
    if def is not null and joined > now() - wait
       and exists (select 1 from public.channels c where c.id = new.channel_id and c.server_id = def) then
      raise exception 'Welcome! New accounts can post here % after signing up.', trim(to_char(wait, 'MI "minutes"')) using errcode = 'check_violation';
    end if;
  end if;
  if new.content ~ '(^|[^A-Za-z0-9_@])@everyone\M' then
    if not exists (
      select 1 from public.channels c
      where c.id = new.channel_id
        and ((c.server_id is not null and public.server_perm(c.server_id, 'manage_messages'))
          or (c.server_id is null and c.kind = 'group'))
    ) then
      new.content := regexp_replace(new.content, '@everyone', '@​everyone', 'g');
    end if;
  end if;
  return new;
end; $function$;
CREATE OR REPLACE FUNCTION public.server_locked(sid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select coalesce((select locked_until > now() from public.servers where id = sid), false);
$function$;
`;

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  const mig = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '193_raid_protection.sql'), 'utf8');
  await h.db.exec(mig);
  await h.db.exec(mig); // re-runnable, patches applied once
  const marks = async (sig) => (await h.one(`select (length(d) - length(replace(d, '193:', ''))) / 4 n from pg_get_functiondef($1::regprocedure) d`, [sig])).n;
  h.eq('join_server patched once', await marks('public.join_server(text)'), 1);
  h.eq('join_public_server patched once', await marks('public.join_public_server(uuid)'), 1);
  h.eq('message_raid_guard patched once', await marks('public.message_raid_guard()'), 1);
  h.eq('flag row in test mode', (await h.one(`select mode from feature_flags where key = 'raid_protection'`)).mode, 'test');

  const owner = await h.signup('owner@test.dev', 'owner');
  const mod = await h.signup('mod@test.dev', 'mod');
  const kid = await h.signup('kid@test.dev', 'kid');
  const kid2 = await h.signup('kid2@test.dev', 'kid2');
  const vet = await h.signup('vet@test.dev', 'vet');
  const staff = await h.signup('staff@test.dev', 'staff');
  const bot = await h.signup('bot@test.dev', 'botty');
  await h.as(owner);
  const A = (await h.one(`select create_server('Server A', null) id`)).id;
  const B = (await h.one(`select create_server('Server B', null) id`)).id;
  await h.admin();
  // Old accounts, except the kids (made 5 minutes ago).
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  await h.q(`update profiles set created_at = now() - interval '5 minutes' where id = any($1)`, [[kid, kid2, staff, bot, mod]]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  await h.q(`update servers set discoverable = true`);
  await h.q(`insert into invites (code, server_id, created_by) values ('raidaaaa', $1, $3), ('raidbbbb', $2, $3)`, [A, B, owner]);
  const chan = async (sid) => (await h.one(`select id from channels where server_id = $1 and kind = 'text' limit 1`, [sid])).id;
  const cA = await chan(A);
  const cB = await chan(B);
  const tryAs = async (uid, sql, params = []) => {
    await h.as(uid);
    try { await h.q(sql, params); return null; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  // The live guard's new-account speed limit (one message every 3 seconds) isn't under test: age earlier messages.
  const post = async (uid, cid, text = 'hi') => {
    await h.db.exec(`set session_replication_role = replica`); // skip the edit guard for this backdate
    await h.q(`update messages set created_at = created_at - interval '1 minute' where author_id = $1`, [uid]);
    await h.db.exec(`set session_replication_role = origin`);
    return tryAs(uid, `insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, uid, text]);
  };
  const member = async (sid, uid) => !!(await h.one(`select 1 x from server_members where server_id = $1 and user_id = $2`, [sid, uid]));

  // ---- RPC: permission + flag ----
  h.eq('flag off: turning it on is refused', (await tryAs(owner, `select set_new_account_rule($1, 60, 'join')`, [A]))?.includes('available'), true);
  h.eq('flag off: turning it off is fine', await tryAs(owner, `select set_new_account_rule($1, 0, 'join')`, [A]), null);
  await h.q(`update feature_flags set servers = array[$1::uuid, $2::uuid] where key = 'raid_protection'`, [A, B]);
  h.eq('a member without Manage Server is refused', (await tryAs(vet, `select set_new_account_rule($1, 60, 'join')`, [A]))?.includes('Manage Server'), true);
  h.eq('bad age refused', (await tryAs(owner, `select set_new_account_rule($1, 30, 'join')`, [A]))?.includes('Pick'), true);
  h.eq('bad mode refused', (await tryAs(owner, `select set_new_account_rule($1, 60, 'nope')`, [A]))?.includes('Pick'), true);
  await tryAs(vet, `update servers set new_account_minutes = 60 where id = $1`, [A]);
  h.eq('a member can\'t write it directly', (await h.one(`select new_account_minutes m from servers where id = $1`, [A])).m, null);
  h.eq('anon can\'t call it', (await tryAs(null, `select set_new_account_rule($1, 0, 'join')`, [A])) !== null, true);

  // ---- off = no effect ----
  h.eq('off: kid joins B by invite', await tryAs(kid2, `select join_server('raidbbbb')`), null);
  h.eq('off: kid2 posts in B', await post(kid2, cB), null);

  // ---- join mode ----
  h.eq('owner sets A: join, 1 hour', await tryAs(owner, `select set_new_account_rule($1, 60, 'join')`, [A]), null);
  h.eq('stored', await h.one(`select new_account_minutes m, new_account_mode d from servers where id = $1`, [A]), { m: 60, d: 'join' });
  h.eq('young account refused by invite', await tryAs(kid, `select join_server('raidaaaa')`), 'This server only lets in accounts older than 1 hour. Try again later.');
  h.eq('young account refused from Discovery', await tryAs(kid, `select join_public_server($1)`, [A]), 'This server only lets in accounts older than 1 hour. Try again later.');
  h.eq('... not a member', await member(A, kid), false);
  h.eq('invite uses unchanged', (await h.one(`select uses from invites where code = 'raidaaaa'`)).uses, 0);
  h.eq('only that server: kid joins B', await tryAs(kid, `select join_server('raidbbbb')`), null);
  h.eq('old account joins A', await tryAs(vet, `select join_server('raidaaaa')`), null);
  h.eq('staff (young) joins A', await tryAs(staff, `select join_server('raidaaaa')`), null);
  h.eq('rejoin as a member is a no-op, not refused', await tryAs(vet, `select join_public_server($1)`, [A]), null);
  h.eq('7 days label', await (async () => { await tryAs(owner, `select set_new_account_rule($1, 10080, 'join')`, [A]); return tryAs(kid, `select join_server('raidaaaa')`); })(),
    'This server only lets in accounts older than 7 days. Try again later.');
  h.eq('10 minutes: 5-minute-old account still refused', await (async () => { await tryAs(owner, `select set_new_account_rule($1, 10, 'join')`, [A]); return tryAs(kid, `select join_server('raidaaaa')`); })(),
    'This server only lets in accounts older than 10 minutes. Try again later.');
  await h.q(`update profiles set created_at = now() - interval '11 minutes' where id = $1`, [kid]);
  h.eq('old enough now: joins', await tryAs(kid, `select join_server('raidaaaa')`), null);
  h.eq('... member', await member(A, kid), true);
  await h.q(`update profiles set created_at = now() - interval '5 minutes' where id = $1`, [kid]);
  h.eq('join mode doesn\'t block posting', await post(kid, cA), null);

  // ---- chat mode ----
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [A, mod, bot]);
  const role = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Mods', 5, '{"manage_messages": true}') returning id`, [A])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [A, mod, role]);
  h.eq('owner sets A: chat, 1 hour', await tryAs(owner, `select set_new_account_rule($1, 60, 'chat')`, [A]), null);
  h.eq('chat mode: young account can join', await tryAs(kid2, `select join_server('raidaaaa')`), null);
  const msg = await post(kid2, cA);
  h.eq('chat mode: posting refused', msg?.startsWith('New accounts can\'t chat here until they\'re 1 hour old. You can chat here in '), true);
  h.eq('... with the wait', /in (5[45]|56) min\.$/.test(msg ?? ''), true);
  h.eq('only that server: kid2 posts in B', await post(kid2, cB), null);
  h.eq('old account posts', await post(vet, cA, 'yo'), null);
  h.eq('manage_messages (young) posts', await post(mod, cA, 'mod here'), null);
  h.eq('staff (young) posts', await post(staff, cA, 'staff here'), null);
  h.eq('bot (young) posts', await (async () => {
    await h.as(bot);
    try { await h.db.exec(`select set_config('yapper.bot', '1', false)`); await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'beep')`, [cA, bot]); return null; }
    catch (e) { return e.message; }
    finally { await h.db.exec(`select set_config('yapper.bot', '', false)`); await h.admin(); }
  })(), null);
  await h.q(`update profiles set created_at = now() - interval '2 hours' where id = $1`, [kid2]);
  h.eq('old enough now: posts', await post(kid2, cA, 'finally'), null);
  await h.q(`update profiles set created_at = now() - interval '5 minutes' where id = $1`, [kid2]);
  h.eq('1 day: hours label', /You can chat here in 24 hours\.$/.test(await (async () => { await tryAs(owner, `select set_new_account_rule($1, 1440, 'chat')`, [A]); return post(kid2, cA); })() ?? ''), true);

  // ---- off again ----
  h.eq('a manager turns it off', await tryAs(owner, `select set_new_account_rule($1, 0, 'chat')`, [A]), null);
  h.eq('off: kid2 posts', await post(kid2, cA, 'free'), null);
  // Flag switched off while a value is set: still enforced, and it can still be turned off.
  await tryAs(owner, `select set_new_account_rule($1, 60, 'chat')`, [A]);
  await h.q(`update feature_flags set servers = '{}' where key = 'raid_protection'`);
  h.eq('value set, flag off: still enforced', (await post(kid2, cA))?.startsWith('New accounts can'), true);
  h.eq('flag off: can\'t turn it on again', (await tryAs(owner, `select set_new_account_rule($1, 60, 'join')`, [A]))?.includes('available'), true);
  h.eq('flag off: can turn it off', await tryAs(owner, `select set_new_account_rule($1, 0, 'join')`, [A]), null);
  h.eq('off', (await h.one(`select new_account_minutes m from servers where id = $1`, [A])).m, null);

  // ---- helpers aren't callable directly ----
  h.eq('join check not callable', (await tryAs(kid, `select new_account_join_check($1)`, [A])) !== null, true);
  h.eq('chat check not callable', (await tryAs(kid, `select new_account_chat_check($1, $2, now())`, [cA, kid])) !== null, true);
}
