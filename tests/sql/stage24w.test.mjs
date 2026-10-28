// 155 channel webhooks. PGlite can't replay migrations 025+ (025 needs storage columns the stubs don't have), so this
// stage starts from stage 24, adds stand-ins for the live pieces 155 builds on (copied from the live definitions where
// it matters: feature_on, server_perm, server_locked, require_scanned_media, the old 5-embed constraint, and the
// moderation functions 155 patches in place), then runs 155.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const sha = (t) => createHash('sha256').update(t).digest('hex');

const LIVE_STANDINS = `
create table if not exists public.feature_flags (
  key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}', updated_at timestamptz default now());
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false);
$$;
alter table public.messages add column if not exists embeds jsonb;
alter table public.messages add column if not exists components jsonb;
alter table public.messages drop constraint if exists messages_content_check;
alter table public.messages add constraint messages_content_check check (
  char_length(content) <= 4000 and (char_length(btrim(content)) > 0 or attachment_path is not null or embeds is not null)) not valid;
alter table public.messages add constraint messages_embeds_shape check (
  embeds is null or (jsonb_typeof(embeds) = 'array' and jsonb_array_length(embeds) between 1 and 5 and octet_length(embeds::text) <= 16000)) not valid;
alter table public.profiles add column if not exists badges text[];
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists muted_reason text;
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.servers add column if not exists locked_until timestamptz;
alter table public.servers add column if not exists everyone_perms jsonb;
alter table public.roles add column if not exists perms jsonb;
alter table public.roles add column if not exists mentionable boolean not null default false;
alter table public.roles add column if not exists auto text not null default 'none';
alter table public.channels add column if not exists category_id uuid;
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid, role_id uuid, allow text[], deny text[]);
create table if not exists public.server_timeouts (server_id uuid, user_id uuid, until timestamptz);
create or replace function public.server_timed_out(sid uuid, uid uuid) returns timestamptz language sql stable security definer set search_path = public as $$
  select until from public.server_timeouts where server_id = sid and user_id = uid and until > now();
$$;
create or replace function public.server_locked(sid uuid) returns boolean language sql stable set search_path = public as $$
  select coalesce((select locked_until > now() from public.servers where id = sid), false);
$$;
create or replace function public.basic_perm(perm text) returns boolean language sql immutable as $$
  select perm in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis', 'create_invite',
                  'change_nickname', 'connect', 'speak', 'create_polls', 'read_history');
$$;
create or replace function public.legacy_manage_server(perm text) returns boolean language sql immutable as $$
  select perm in ('manage_server', 'manage_channels', 'manage_roles', 'manage_emojis', 'kick_members', 'ban_members',
                  'timeout_members', 'manage_nicknames', 'manage_messages', 'mention_everyone', 'mute_members', 'move_members');
$$;
create or replace function public.legacy_manage_messages(perm text) returns boolean language sql immutable as $$
  select perm in ('manage_messages', 'timeout_members', 'manage_nicknames', 'mention_everyone', 'mute_members');
$$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select sid is not null and (
    exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (
      select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
      where mr.server_id = sid and mr.user_id = auth.uid()
        and (coalesce((r.perms->>'administrator')::boolean, false)
          or (r.manage_server and public.legacy_manage_server(perm))
          or (r.manage_messages and public.legacy_manage_messages(perm))
          or coalesce((r.perms->>perm)::boolean, false)))
    or (public.basic_perm(perm) and public.is_server_member(sid)
        and coalesce(((select everyone_perms from public.servers where id = sid)->>perm)::boolean, true)));
$$;
-- Overrides, cut down: owner always, else a channel-level deny wins over the role grant.
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql stable as $$
  select exists (select 1 from public.channels c join public.servers s on s.id = c.server_id where c.id = cid and s.owner_id = uid)
      or (coalesce(base, false) and not exists (select 1 from public.channel_overrides o where o.channel_id = cid and perm = any(o.deny)));
$$;
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable as $$ select false $$;
create or replace function public.has_self_harm_incitement(t text) returns boolean language sql immutable as $$ select t ~* 'kill yourself' $$;
create or replace function public.bad_name(t text) returns boolean language sql immutable set search_path = public as $$ select public.has_slur(t) $$;
create table if not exists public.media_scans (bucket text, path text, user_id uuid, score real, verdict text, primary key (bucket, path));
create or replace function public.media_ok(b text, p text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.media_scans where bucket = b and path = p and verdict = 'ok');
$$;
create or replace function public.require_scanned_media() returns trigger language plpgsql security definer set search_path = public as $$
declare i int; col text; b text; val text; old_val text; sid uuid; strict_server boolean := false; cid uuid;
begin
  cid := (to_jsonb(new) ->> 'channel_id')::uuid;
  if cid is not null then
    select c.server_id into sid from public.channels c where c.id = cid;
    strict_server := sid is not null and sid = (select default_server_id from public.app_settings limit 1)
                     and not public.channel_allows(cid, 'manage_messages');
  end if;
  for i in 0 .. (tg_nargs / 2) - 1 loop
    col := tg_argv[i * 2]; b := tg_argv[i * 2 + 1];
    val := to_jsonb(new) ->> col;
    old_val := case when tg_op = 'UPDATE' then to_jsonb(old) ->> col else null end;
    if val is not null and val is distinct from old_val then
      if not public.media_ok(b, val) then raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation'; end if;
      if strict_server and exists (select 1 from public.media_scans s where s.bucket = b and s.path = val and s.score >= 0.6) then
        raise exception 'That picture is too close to the line for Yapper HQ.' using errcode = 'check_violation';
      end if;
    end if;
  end loop;
  return new;
end $$;
create table if not exists public.site_moderators (user_id uuid primary key);
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin();
$$;
alter table public.reports add column if not exists server_id uuid;
alter table public.reports add column if not exists triage text;
alter table public.reports add column if not exists triage_note text;
`;

/**
 * The moderation functions 155 patches in place, copied verbatim from the live database (read-only), so the patch
 * markers are checked against the real text.
 */
const LIVE_MODERATION = `
CREATE OR REPLACE FUNCTION public.report_guard(reporter uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if reporter is null then raise exception 'You need to be logged in'; end if;
  if (select count(*) from public.reports where reporter_id = reporter and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'You''ve sent a lot of reports. Try again later.';
  end if;
end;
$function$;
CREATE OR REPLACE FUNCTION public.report_message(mid uuid, why text, more text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m public.messages; rid uuid; ev jsonb; k text;
begin
  perform public.report_guard(auth.uid());
  select * into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'Message not found'; end if;
  if m.author_id = auth.uid() then raise exception 'You can''t report your own message'; end if;
  select kind into k from public.channels where id = m.channel_id;
  -- Context: the 12 messages around it in the same chat (so DM reports can be judged without reading the whole DM).
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'channel_id', x.channel_id, 'content', x.content, 'attachment', x.attachment_path, 'created_at', x.created_at,
      'author_id', x.author_id, 'kind', k) order by x.created_at), '[]'::jsonb)
    into ev
  from (
    (select * from public.messages where channel_id = m.channel_id and created_at <= m.created_at and id <> m.id order by created_at desc limit 8)
    union all
    (select * from public.messages where channel_id = m.channel_id and created_at > m.created_at order by created_at limit 4)
  ) x;
  insert into public.reports (reporter_id, target_id, message_id, channel_id, message_content, message_attachment, reason, details, evidence, server_id)
  values (auth.uid(), m.author_id, m.id, m.channel_id, m.content, m.attachment_path, why, left(coalesce(more, ''), 1000), ev, (select server_id from public.channels where id = m.channel_id))
  returning id into rid;
  return rid;
end;
$function$;
CREATE OR REPLACE FUNCTION public.apply_auto_action(target uuid, r reports)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare reporters_1h int; reporters_7d int; mu timestamptz; slur boolean;
begin
  if target is null or exists (select 1 from public.site_admins where user_id = target) or exists (select 1 from public.site_bans where user_id = target) then return null; end if;
  slur := public.has_slur(coalesce(r.message_content, ''));
  select count(distinct x.reporter_id) into reporters_1h from public.reports x
    where x.target_id = target and x.created_at > now() - interval '1 hour' and public.trusted_reporter(x.reporter_id);
  select count(distinct x.reporter_id) into reporters_7d from public.reports x
    where x.target_id = target and x.created_at > now() - interval '7 days' and public.trusted_reporter(x.reporter_id);
  if (slur and reporters_7d >= 2) or reporters_1h >= 10 then
    insert into public.site_bans (user_id, reason)
    values (target, case when slur then 'Auto-ban: slurs, reported by ' || reporters_7d || ' people' else 'Auto-ban: reported by ' || reporters_1h || ' trusted people in an hour' end)
    on conflict (user_id) do nothing;
    update public.reports set status = 'actioned', triage = 'auto', triage_note = 'Auto-banned', resolved_at = now() where target_id = target and status = 'open';
    return 'Auto-banned';
  end if;
  if reporters_1h >= 5 then
    select muted_until into mu from public.profiles where id = target;
    if mu is null or mu < now() then
      update public.profiles set muted_until = now() + interval '1 hour', muted_reason = 'reported by ' || reporters_1h || ' people' where id = target;
    end if;
    return 'Auto timeout 1h';
  end if;
  return null;
end;
$function$;
CREATE OR REPLACE FUNCTION public.mod_purge_messages(uid uuid, hours integer, why text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int; r text := left(btrim(coalesce(why, '')), 500);
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  perform public.mod_guard('purge', uid, r);
  perform public.require_staff_reauth();
  hours := least(greatest(coalesce(hours, 24), 1), 24 * 30);
  execute 'with gone as (del' || 'ete from public.messages where author_id = $1 and created_at > now() - make_interval(hours => $2) returning 1) select count(*) from gone'
    into n using uid, hours;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'purge', uid, r || ' (' || n || ' messages, last ' || hours || 'h)');
  return n;
end $function$;
CREATE OR REPLACE FUNCTION public.site_ban(uid uuid, why text DEFAULT ''::text, wipe boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if uid = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;
  insert into public.site_bans (user_id, reason, banned_by) values (uid, left(coalesce(why, ''), 500), auth.uid())
  on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  if wipe then
    perform public.require_staff_reauth();
    delete from public.messages where author_id = uid;
  end if;
  -- Close their open reports as handled.
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now()
   where target_id = uid and status = 'open';
end;
$function$;
`;

/** Live triggers skip bot-posted rows (yapper.bot = 1); the stage-24 copies predate that. */
const BOT_SKIP = `
do $$
declare f text; src text;
begin
  foreach f in array array['message_raid_guard', 'message_slowmode'] loop
    src := pg_get_functiondef(('public.' || f || '()')::regprocedure);
    src := regexp_replace(src, '\\mbegin\\M', 'begin if current_setting(''yapper.bot'', true) = ''1'' then return new; end if;');
    execute src;
  end loop;
end $$;
`;

/** The stand-ins plus 155 (twice: it must re-run cleanly). 483's test reuses this, then runs `checks` on top of 483. */
export async function prepare(h) {
  await h.db.exec(LIVE_STANDINS);
  await h.db.exec(LIVE_MODERATION);
  await h.db.exec(BOT_SKIP);
  // LF like the template strings above: a CRLF checkout (Windows) otherwise misses 155's patch anchors.
  const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '155_webhooks.sql'), 'utf8').replace(/\r\n/g, '\n');
  await h.db.exec(MIGRATION);
  await h.ok('155 re-runs cleanly', () => h.db.exec(MIGRATION));
}

export default async function (h) {
  await prepare(h);
  await checks(h);
}

export async function checks(h) {
  h.eq('moderation patches applied once', (await h.one(`select
      (select count(*) from regexp_matches(pg_get_functiondef('public.report_message(uuid,text,text)'::regprocedure), 'webhook_id', 'g'))::int r,
      (select count(*) from regexp_matches(pg_get_functiondef('public.site_ban(uuid,text,boolean)'::regprocedure), 'webhook_user_id', 'g'))::int s`)), { r: 1, s: 1 });
  // Item 7: the messages guard only runs when the column is set or changed.
  h.eq('messages guard triggers are conditional', (await h.q(`select tgname, pg_get_triggerdef(oid) ~ 'WHEN' w from pg_trigger
      where tgrelid = 'public.messages'::regclass and tgname like 'messages_webhook%' order by tgname`)).map((r) => [r.tgname, r.w]),
    [['messages_webhook_insert', true], ['messages_webhook_update', true]]);

  const service = async () => { await h.db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role service_role;`); };
  const err = async (sql, params = []) => { try { await h.db.query(sql, params); return null; } catch (e) { return e; } };
  const clearRate = async () => { await h.admin(); await h.q(`delete from webhook_rate`); await service(); };
  const send = (id, tok, body, extra = {}) => h.one(
    `select * from webhook_send($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb)`,
    [id, tok, body, extra.username ?? null, extra.avatar ?? null, extra.embeds ? JSON.stringify(extra.embeds) : null, extra.mentions ? JSON.stringify(extra.mentions) : null],
  );

  h.eq('flag row is test-only', await h.one(`select mode, servers from feature_flags where key = 'webhooks'`), { mode: 'test', servers: [] });

  const boss = await h.signup('boss@test.dev', 'boss');
  const hooky = await h.signup('hooky@test.dev', 'hooky');
  const pleb = await h.signup('pleb@test.dev', 'pleb');
  const sys = await h.signup('webhooks@test.dev', 'webhookbot');
  const staffer = await h.signup('zed@test.dev', 'zed');
  const adm = await h.signup('adm@test.dev', 'boss_admin');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staffer]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [adm]);
  await h.as(boss);
  const sid = (await h.one(`select create_server('Hooks', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and kind='text' limit 1`, [sid])).id;
  await h.admin();
  const voice = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('voice', 'Talk', $1, $2) returning id`, [sid, boss])).id;
  const role = (await h.one(`insert into roles (server_id, name, position, manage_server, manage_messages, perms) values ($1, 'Hookers', 1, false, false, '{"manage_webhooks": true}') returning id`, [sid])).id;
  const pingRole = (await h.one(`insert into roles (server_id, name, position, manage_server, manage_messages) values ($1, 'Pingers', 1, false, false) returning id`, [sid])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, hooky, pleb]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, hooky, role]);

  // ---- the flag ----
  await h.as(boss);
  await h.fails('flag off: no webhooks', `select webhook_create($1, 'Alerts')`, [gen]);
  await h.admin();
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'webhooks'`, [sid]);

  // ---- managing ----
  await h.as(boss);
  const made = (await h.one(`select webhook_create($1, '  Build   bot ') w`, [gen])).w;
  h.eq('token is 64 hex', /^[0-9a-f]{64}$/.test(made.token), true);
  h.eq('name tidied', made.name, 'Build bot');
  await h.fails('voice channels have no webhooks', `select webhook_create($1, 'x')`, [voice]);
  await h.fails('names with yapper refused', `select webhook_create($1, 'Yapper Staff')`, [gen]);
  await h.fails('slur names refused', `select webhook_create($1, 'retard')`, [gen]);
  // Item 4: look-alikes, digit swaps, invisible characters, staff names.
  for (const bad of ['Yapp3r news', 'Y​apper', 'Y⁠A‍P­PER', 'ADMIN', 'Server Adm1n', 'mod squad', 'Support', '0fficial bot', 'zed', 'Z3D'])
    await h.fails(`name refused: ${JSON.stringify(bad)}`, `select webhook_create($1, $2)`, [gen, bad]);
  await h.admin();
  await h.q(`update profiles set display_name = 'Zed Prime' where id = $1`, [staffer]);
  await h.as(boss);
  await h.fails('staff display name refused', `select webhook_create($1, 'zed  PRIME')`, [gen]);
  const ok1 = (await h.one(`select webhook_create($1, $2) w`, [gen, 'Mo​del trains'])).w;
  h.eq('invisible characters are removed from names', ok1.name, 'Model trains');
  await h.q(`select webhook_delete($1)`, [ok1.id]);
  await h.admin();
  const row =await h.one(`select token_hash, created_by from webhooks where id = $1`, [made.id]);
  h.eq('only the hash is stored', row.token_hash, sha(made.token));
  h.eq('creator recorded', row.created_by, boss);

  await h.as(pleb);
  await h.fails('no Manage Webhooks: no create', `select webhook_create($1, 'x')`, [gen]);
  await h.fails('no Manage Webhooks: no list', `select * from webhook_list($1)`, [gen]);
  await h.fails('no Manage Webhooks: no rotate', `select webhook_rotate($1)`, [made.id]);
  await h.fails('no Manage Webhooks: no delete', `select webhook_delete($1)`, [made.id]);
  await h.fails('table not readable', `select * from webhooks`);
  await h.fails('cannot post through the API function', `select webhook_send($1, $2, 'hi')`, [made.id, made.token]);
  await h.fails('cannot claim the author account', `select webhook_claim_author($1)`, [pleb]);
  await h.fails('cannot set pictures directly', `select webhook_set_avatar($1, $2, null)`, [pleb, made.id]);
  await h.as(null);
  await h.fails('anon cannot post through the API function', `select webhook_send($1, $2, 'hi')`, [made.id, made.token]);

  await h.as(hooky);
  const second = (await h.one(`select webhook_create($1, 'Second') w`, [gen])).w;
  h.eq('role with manage_webhooks lists them', (await h.q(`select name from webhook_list($1)`, [gen])).map((r) => r.name), ['Build bot', 'Second']);
  await h.q(`select webhook_rename($1, 'Deploys')`, [second.id]);
  for (let i = 0; i < 8; i++) await h.q(`select webhook_create($1, $2)`, [gen, `Hook ${i}`]);
  await h.fails('10 per channel', `select webhook_create($1, 'Eleven')`, [gen]);
  await h.q(`select webhook_delete($1)`, [second.id]);
  h.eq('delete frees a slot', (await h.q(`select * from webhook_list($1)`, [gen])).length, 9);

  // ---- sending ----
  await service();
  const e0 = await err(`select webhook_send($1, $2, 'hi')`, [made.id, made.token]);
  h.eq('no shared account yet: setup hint', e0?.hint, 'webhook:setup');
  h.eq('claim stores the account', (await h.one(`select webhook_claim_author($1) id`, [sys])).id, sys);
  h.eq('a second claim keeps the first', (await h.one(`select webhook_claim_author($1) id`, [pleb])).id, sys);

  h.eq('wrong token', (await err(`select webhook_send($1, $2, 'hi')`, [made.id, 'f'.repeat(64)]))?.hint, 'webhook:50027');
  h.eq('bad token shape', (await err(`select webhook_send($1, $2, 'hi')`, [made.id, 'nope']))?.hint, 'webhook:50027');
  h.eq('unknown webhook', (await err(`select webhook_send(gen_random_uuid(), $1, 'hi')`, [made.token]))?.hint, 'webhook:10015');
  h.eq('empty message', (await err(`select webhook_send($1, $2, '  ')`, [made.id, made.token]))?.hint, 'webhook:50006');

  const m1 = await send(made.id, made.token, 'deploy done', { embeds: [{ title: 'Build #42', color: 5793266 }] });
  h.eq('posted as the shared account', m1.author_id, sys);
  h.eq('webhook stamp', { id: m1.webhook.id, name: m1.webhook.name }, { id: made.id, name: 'Build bot' });
  h.eq('embeds kept', m1.embeds[0].title, 'Build #42');
  await clearRate();
  const m2 = await send(made.id, made.token, 'x', { username: 'CI', avatar: 'https://i.imgur.com/a.png' });
  h.eq('username and avatar override', { name: m2.webhook.name, url: m2.webhook.avatar_url }, { name: 'CI', url: 'https://i.imgur.com/a.png' });
  h.eq('non-https avatar ignored', (await send(made.id, made.token, 'x2', { avatar: 'http://evil.test/a.png' })).webhook.avatar_url, null);
  await clearRate();
  h.eq('bad username refused', !!(await err(`select webhook_send($1, $2, 'x', 'Yapper Official')`, [made.id, made.token])), true);
  h.eq('slur in an embed refused', (await err(`select webhook_send($1, $2, 'x', null, null, $3::jsonb)`, [made.id, made.token, JSON.stringify([{ description: 'you retard' }])]))?.hint, 'webhook:200000');
  h.eq('adult link in an embed refused', (await err(`select webhook_send($1, $2, 'x', null, null, $3::jsonb)`, [made.id, made.token, JSON.stringify([{ url: 'https://pornhub.com/x', title: 'hi' }])]))?.hint, 'webhook:200000');
  await h.fails('adult link in content refused (message trigger)', `select webhook_send($1, $2, 'look pornhub.com')`, [made.id, made.token]);
  await clearRate();
  const ten = Array.from({ length: 10 }, (_, i) => ({ title: `e${i}` }));
  h.eq('10 embeds fit', (await send(made.id, made.token, '', { embeds: ten })).embeds.length, 10);
  h.eq('11 embeds refused', (await err(`select webhook_send($1, $2, '', null, null, $3::jsonb)`, [made.id, made.token, JSON.stringify([...ten, { title: 'x' }])]))?.hint, 'webhook:50035');
  h.eq('2001 characters refused', (await err(`select webhook_send($1, $2, $3)`, [made.id, made.token, 'a'.repeat(2001)]))?.hint, 'webhook:50035');

  // ---- mentions ----
  await clearRate();
  h.eq('@everyone off by default', (await send(made.id, made.token, 'hey @everyone and @here')).content, 'hey @​everyone and @​here');
  h.eq('@everyone when allowed and the owner made it', (await send(made.id, made.token, 'hey @everyone', { mentions: { parse: ['everyone'] } })).content, 'hey @everyone');
  await h.admin();
  const hookyMade = await h.one(`select id from webhooks where created_by = $1 and name = 'Hook 0'`, [hooky]);
  await h.q(`update webhooks set token_hash = $2 where id = $1`, [hookyMade.id, sha('a'.repeat(64))]);
  await service();
  h.eq('@everyone stays off when the creator lacks Mention @everyone', (await send(hookyMade.id, 'a'.repeat(64), '@everyone', { mentions: { parse: ['everyone'] } })).content, '@​everyone');
  await clearRate();
  h.eq('role pings off by default', (await send(made.id, made.token, `hi <@&${pingRole}>`)).content, 'hi @​Pingers');
  h.eq('user pings on by default', (await send(made.id, made.token, `hi <@${pleb}>`)).content, `hi <@${pleb}>`);
  h.eq('user pings off with parse []', (await send(made.id, made.token, `hi <@${pleb}>`, { mentions: { parse: [] } })).content, 'hi @​pleb');
  await clearRate();
  h.eq('listed user still pinged', (await send(made.id, made.token, `hi <@${pleb}>`, { mentions: { parse: [], users: [pleb] } })).content, `hi <@${pleb}>`);

  // ---- rate limits (item 3: webhook_take is its own call, so failed sends still count) ----
  const take = async (id, tok) => (await h.one(`select webhook_take($1, $2) t`, [id, tok])).t;
  await clearRate();
  h.eq('take: wrong token counts nothing', await take(made.id, 'f'.repeat(64)), { code: 50027 });
  h.eq('take: unknown webhook', await take('00000000-0000-4000-8000-000000000009', made.token), { code: 10015 });
  h.eq('take: wrong tokens left no counter', (await h.one(`select count(*)::int n from webhook_rate`)).n, 0);
  for (let i = 0; i < 5; i++) {
    h.eq(`take ${i + 1} of 5 fits`, await take(made.id, made.token), { ok: true });
    await err(`select webhook_send($1, $2, '   ')`, [made.id, made.token]); // fails: empty
  }
  const sixth = await take(made.id, made.token);
  h.eq('failed sends still counted: 6th in 2 seconds is limited', sixth.code === 429 && sixth.retry_after > 0, true);
  await clearRate();
  await h.admin();
  await h.q(`insert into webhook_rate (k, bucket, n) values ($1, floor(extract(epoch from clock_timestamp()) / 60), 30)`, [`c:${gen}`]);
  await service();
  h.eq('channel cap of 30 a minute', (await take(made.id, made.token)).code, 429);
  await clearRate();
  await h.as(pleb);
  await h.fails('signed-in users cannot call webhook_take', `select webhook_take($1, $2)`, [made.id, made.token]);
  await service();

  // ---- item 1: the creator's standing is checked on every send ----
  const hk = 'a'.repeat(64);
  const sendHook = () => err(`select webhook_send($1, $2, 'standing check')`, [hookyMade.id, hk]);
  h.eq('creator in good standing posts', await sendHook(), null);
  await h.admin();
  await h.q(`delete from member_roles where user_id = $1 and role_id = $2`, [hooky, role]);
  await service();
  const lost = await sendHook();
  h.eq('creator lost Manage Webhooks: refused', [lost?.hint, /Manage Webhooks/.test(lost?.message ?? '')], ['webhook:50001', true]);
  await h.admin();
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, hooky, role]);
  await h.q(`insert into server_timeouts (server_id, user_id, until) values ($1, $2, now() + interval '1 hour')`, [sid, hooky]);
  await service();
  h.eq('creator timed out in the server: refused', (await sendHook())?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`update profiles set muted_until = now() + interval '1 hour' where id = $1`, [hooky]);
  await h.as(hooky);
  await h.fails('item 5: timed-out manager cannot list', `select * from webhook_list($1)`, [gen]);
  await h.admin();
  await h.q(`delete from server_timeouts where user_id = $1`, [hooky]);
  await service();
  h.eq('creator timed out site-wide: refused', (await sendHook())?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`update profiles set muted_until = null where id = $1`, [hooky]);
  await h.q(`update channels set private = true where id = $1`, [gen]);
  await service();
  const hidden = await sendHook();
  h.eq('creator can no longer see the channel: refused', [hidden?.hint, /see the channel/.test(hidden?.message ?? '')], ['webhook:50001', true]);
  await h.as(hooky);
  await h.fails('item 5: manager who cannot see the channel cannot list', `select * from webhook_list($1)`, [gen]);
  await h.admin();
  await h.q(`update channels set private = false where id = $1`, [gen]);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [sid, hooky]);
  await service();
  h.eq('creator left the server: refused', (await sendHook())?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, hooky]);
  // Leaving the server took the role with it.
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3) on conflict do nothing`, [sid, hooky, role]);
  // Item 5: Manage Webhooks is channel-aware (a channel override can take it away).
  await h.q(`insert into feature_flags (key, mode, servers) values ('channel_perms', 'test', array[$1::uuid]) on conflict (key) do update set mode = 'test', servers = excluded.servers`, [sid]);
  await h.q(`insert into channel_overrides (channel_id, allow, deny) values ($1, '{}', '{manage_webhooks}')`, [gen]);
  await h.as(hooky);
  await h.fails('item 5: channel override denies Manage Webhooks', `select * from webhook_list($1)`, [gen]);
  await h.as(boss);
  h.eq('item 5: owner still manages', (await h.q(`select id from webhook_list($1)`, [gen])).length > 0, true);
  await service();
  h.eq('item 1: override applies to sends too', (await sendHook())?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`delete from channel_overrides where channel_id = $1`, [gen]);
  await service();
  h.eq('creator back in good standing posts again', await sendHook(), null);
  h.eq('caller identity restored after the check', (await h.one(`select auth.uid() u`)).u, null);
  await clearRate();

  // ---- item 2: moderation goes to the webhook's creator, never the shared account ----
  await h.as(pleb);
  const rid = (await h.one(`select report_message($1, 'spam', '') r`, [m1.id])).r;
  await h.admin();
  h.eq('report targets the creator and keeps the webhook', await h.one(`select target_id, webhook_id from reports where id = $1`, [rid]), { target_id: boss, webhook_id: made.id });
  h.eq('auto actions skip the shared account', (await h.one(`select apply_auto_action($1, r) a from reports r where r.id = $2`, [sys, rid])).a, null);
  await h.as(adm);
  const sb = await err(`select site_ban($1, 'x')`, [sys]);
  h.eq('site_ban refuses the shared account', /shared webhook account/.test(sb?.message ?? ''), true);
  const pg = await err(`select mod_purge_messages($1, 24, 'x')`, [sys]);
  h.eq('mod_purge refuses the shared account', /shared webhook account/.test(pg?.message ?? ''), true);
  await service();

  // ---- the webhook column is only for webhook_send ----
  await h.as(pleb);
  const own = await h.one(`insert into messages (channel_id, author_id, content, webhook) values ($1, $2, 'fake', '{"name": "Admin"}') returning id, webhook`, [gen, pleb]);
  h.eq('people cannot stamp a webhook on their message', own.webhook, null);
  await h.admin();
  await h.q(`update messages set webhook = '{"name": "Changed"}' where id = $1`, [m1.id]);
  h.eq('nobody changes it later', (await h.one(`select webhook from messages where id = $1`, [m1.id])).webhook.name, 'Build bot');

  // ---- pictures ----
  await service();
  h.eq('no perm: no manage channel', (await h.one(`select webhook_manage_channel($1, $2) c`, [pleb, made.id])).c, null);
  h.eq('perm: manage channel', (await h.one(`select webhook_manage_channel($1, $2) c`, [hooky, made.id])).c, gen);
  await h.fails('unscanned picture refused', `select webhook_set_avatar($1, $2, 'webhooks/x/a.png')`, [boss, made.id]);
  await h.fails('picture outside webhooks/ refused', `select webhook_set_avatar($1, $2, 'someone/a.png')`, [boss, made.id]);
  await h.admin();
  await h.q(`insert into media_scans (bucket, path, verdict, score) values ('avatars', 'webhooks/x/a.png', 'ok', 0)`);
  await service();
  await h.q(`select webhook_set_avatar($1, $2, 'webhooks/x/a.png')`, [boss, made.id]);
  await h.fails('no perm: no picture', `select webhook_set_avatar($1, $2, null)`, [pleb, made.id]);
  h.eq('webhook picture on new messages', (await send(made.id, made.token, 'pic')).webhook.avatar_path, 'webhooks/x/a.png');

  // ---- new URL, bans, server state ----
  await h.as(boss);
  const tok2 = (await h.one(`select webhook_rotate($1) t`, [made.id])).t;
  await service();
  h.eq('old URL stops working', (await err(`select webhook_send($1, $2, 'x')`, [made.id, made.token]))?.hint, 'webhook:50027');
  await send(made.id, tok2, 'new url works');
  await h.admin();
  await h.q(`update servers set locked_until = now() + interval '1 hour' where id = $1`, [sid]);
  await service();
  await send(made.id, tok2, 'owner made it, so a lock does not stop it');
  h.eq('locked server stops a non-mod creator', (await err(`select webhook_send($1, $2, 'x')`, [hookyMade.id, 'a'.repeat(64)]))?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`update servers set locked_until = null where id = $1`, [sid]);
  await h.q(`insert into server_bans (server_id, user_id, banned_by) values ($1, $2, $3)`, [sid, hooky, boss]);
  await service();
  await clearRate();
  h.eq('creator banned from the server: refused', (await err(`select webhook_send($1, $2, 'x')`, [hookyMade.id, 'a'.repeat(64)]))?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`update feature_flags set servers = '{}' where key = 'webhooks'`);
  await service();
  h.eq('flag off: refused', (await err(`select webhook_send($1, $2, 'x')`, [made.id, tok2]))?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'webhooks'`, [sid]);
  await h.q(`delete from channels where id = $1`, [gen]);
  h.eq('deleting the channel removes its webhooks', (await h.one(`select count(*)::int n from webhooks where channel_id = $1`, [gen])).n, 0);
  await service();
  h.eq('deleted channel: unknown webhook', (await err(`select webhook_send($1, $2, 'x')`, [made.id, tok2]))?.hint, 'webhook:10015');

  // ---- site bans ----
  await h.admin();
  const gen2 = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'two', $1, $2) returning id`, [sid, boss])).id;
  await h.q(`delete from server_bans where user_id = $1`, [hooky]);
  await h.as(hooky);
  const late = (await h.one(`select webhook_create($1, 'Late') w`, [gen2])).w;
  await h.admin();
  await h.q(`insert into site_bans (user_id) values ($1)`, [hooky]);
  await h.as(hooky);
  await h.fails('site-banned: no managing', `select * from webhook_list($1)`, [gen2]);
  await service();
  h.eq('site-banned: no pictures', (await h.one(`select webhook_manage_channel($1, $2) c`, [hooky, late.id])).c, null);
  h.eq('site-banned creator: webhook stops', (await err(`select webhook_send($1, $2, 'x')`, [late.id, late.token]))?.hint, 'webhook:50001');
  await h.admin();
}
