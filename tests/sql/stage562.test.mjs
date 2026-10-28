// 562: @here pings the people who are online right now. Stand-ins for what 546 runs next to (PGlite stops at 024):
// presence (058, with the live-only pref column), roles.perms (044), channel overrides (142), bots, the live copies
// of unread_counts_for / unread_counts_v1 (from stage372) and broadcast_message_change (from 316).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '562_mention_here.sql'), 'utf8');
// 546 patches the same unread counter (forwards are not mentions): applied first, as live, so both patches compose.
const MIG546 = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '546_forwards_not_mentions.sql'), 'utf8');
const MIG316 = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '316_db_load_cuts.sql'), 'utf8');
const S372 = readFileSync(join(here, 'stage372.test.mjs'), 'utf8');
// The live text of the unread counters, as stage372 keeps it (before 372's own "down" patch, which 546 doesn't touch).
const UNREAD = S372.slice(S372.indexOf('CREATE OR REPLACE FUNCTION public.unread_counts_for'), S372.indexOf('CREATE OR REPLACE FUNCTION public.broadcast_member_change'));
const BMC = MIG316.slice(MIG316.indexOf('create or replace function public.broadcast_message_change'), MIG316.indexOf('end; $$;', MIG316.indexOf('create or replace function public.broadcast_message_change')) + 'end; $$;'.length);

const ZW = '​';
const TEST_SERVER = '00000000-0000-4000-8000-00000000b001';

const STANDINS = String.raw`
alter table public.channels add column if not exists private boolean not null default false;
alter table public.channels add column if not exists category_id uuid;
alter table public.messages add column if not exists reply_to_id uuid;
alter table public.messages add column if not exists webhook jsonb;
alter table public.roles add column if not exists perms jsonb not null default '{}'::jsonb;
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid, category_id uuid, role_id uuid, allow text[] not null default '{}', deny text[] not null default '{}');
create table if not exists public.presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  status text not null default 'online' check (status in ('online', 'idle', 'dnd')),
  last_seen timestamptz not null default now(),
  online_since timestamptz not null default now(),
  status_at timestamptz not null default now(),
  pref text
);
alter table public.presence enable row level security;
create table if not exists public.bots (id uuid primary key, owner_id uuid, name text);
create table if not exists public.bot_accounts (bot_id uuid, user_id uuid);
create table if not exists public.app_settings (id int, rt_mode text);
create table if not exists public.sent (topic text, event text, payload jsonb);
create or replace function public.is_staff() returns boolean language sql stable as $$ select false $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable as $$ select coalesce(current_setting('test.banned', true), '') = uid::text $$;
create or replace function public.can_access_channel(cid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.auto_role_applies(rid uuid, uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.my_role_pings() returns table(sid uuid, pats text[]) language sql stable as $$ select null::uuid, null::text[] where false $$;
create or replace function public.channel_overrides_live(cid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable security definer set search_path = public as $$
  select c.* from public.channels c join public.server_members m on m.server_id = c.server_id and m.user_id = auth.uid() $$;
-- Owner, or a role whose perms grant it (the shape of the live server_perm; legacy bits left out).
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid())
      or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                 where mr.server_id = sid and mr.user_id = auth.uid() and coalesce((r.perms->>perm)::boolean, false)) $$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select public.server_perm((select c.server_id from public.channels c where c.id = cid), perm) $$;
-- Overrides live: a channel-level @everyone deny on view_channel beats the base answer (enough for the test).
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.channel_overrides o where o.channel_id = cid and o.role_id is null and perm = any(o.deny))
              then exists (select 1 from public.servers s join public.channels c on c.server_id = s.id where c.id = cid and s.owner_id = uid)
              else coalesce(base, false) end $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return (select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false));
end $$;
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
  returns void language plpgsql security definer set search_path = public as $$
begin insert into public.sent values (topic_name, event_name, jsonb_build_object('operation', operation)); end $$;
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb)
  returns void language sql security definer set search_path = public as $$
  insert into public.sent values (topic_name, event_name, payload);
$$;
alter table public.messages disable trigger messages_raid_guard;
`;

export default async function (h) {
  h.eq('562 has no drop / delete / truncate', /\b(drop|delete\s+from|truncate)\b/i.test(MIG), false);
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(UNREAD);
  await h.db.exec(BMC);
  await h.db.exec(`create or replace trigger messages_broadcast after insert or update or delete on public.messages for each row execute function public.broadcast_message_change()`);

  // A live function whose text drifted: the migration stops instead of patching blind.
  await h.db.exec(UNREAD.replace(`select m.content, m.reply_to_id from public.messages m`, `select m.content,m.reply_to_id from public.messages m`));
  let stopped = '';
  try { await h.db.exec(MIG); } catch (e) { stopped = e.message; }
  h.eq('a drifted anchor stops the migration', /unread_counts_for\(public\.channels\[\]\) changed: anchor 1 expected once, found 0/.test(stopped), true);
  await h.db.exec(UNREAD);
  await h.db.exec(MIG546);
  await h.db.exec(MIG);
  await h.ok('562 re-runs cleanly', () => h.db.exec(MIG));
  for (const [fn, mark] of [['unread_counts_for(channels[])', 'any(f.here_to)'], ['unread_counts_v1()', 'any(f.here_to)'], ['broadcast_message_change()', `'here_to', case when cardinality(new.here_to) <= 200 then new.here_to end`]]) {
    const d = (await h.one(`select pg_get_functiondef('public.${fn}'::regprocedure) d`)).d;
    h.eq(`${fn} patched once`, d.split(mark).length - 1, 1);
  }
  h.eq('546 and 562 both hold', (await h.one(`select pg_get_functiondef('public.unread_counts_for(channels[])'::regprocedure) d`)).d.includes('chr(8618)'), true);
  const flag = await h.one(`select mode, servers from public.feature_flags where key = 'mention_here'`);
  h.eq('flag mention_here in test mode', flag.mode, 'test');
  const can = async (role, fn) => (await h.one(`select has_function_privilege($1, $2, 'execute') ok`, [role, `public.${fn}`])).ok;
  h.eq('nobody signed in can call here_targets', [await can('anon', 'here_targets(uuid, uuid, uuid, boolean)'), await can('authenticated', 'here_targets(uuid, uuid, uuid, boolean)')], [false, false]);
  h.eq('nobody signed in can call here_can_view', [await can('anon', 'here_can_view(uuid, uuid, boolean)'), await can('authenticated', 'here_can_view(uuid, uuid, boolean)')], [false, false]);

  // People: owner, a member with the permission (role), plain members in every presence state, a bot.
  const owner = await h.signup('owner546@x.test', 'owner546');
  const mod = await h.signup('mod546@x.test', 'mod546');
  const online = await h.signup('online546@x.test', 'online546');
  const idle = await h.signup('idle546@x.test', 'idle546');
  const dnd = await h.signup('dnd546@x.test', 'dnd546');
  const gone = await h.signup('gone546@x.test', 'gone546');
  const ghost = await h.signup('ghost546@x.test', 'ghost546');
  const bot = await h.signup('bot546@x.test', 'bot546');
  const outsider = await h.signup('out546@x.test', 'out546');
  await h.admin();
  // The HQ test server id is in the flag: make the server with that id so the flag covers it.
  const sid = (await h.one(`insert into public.servers (id, name, owner_id) values ($1, 'HQ', $2) returning id`, [TEST_SERVER, owner])).id;
  const other = (await h.one(`insert into public.servers (name, owner_id) values ('elsewhere', $1) returning id`, [owner])).id;
  for (const u of [owner, mod, online, idle, dnd, gone, ghost, bot]) {
    await h.q(`insert into public.server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '1 day') on conflict do nothing`, [sid, u]);
  }
  await h.q(`insert into public.server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '1 day'), ($1, $3, now() - interval '1 day') on conflict do nothing`, [other, online, outsider]);
  await h.q(`insert into public.bots (id, owner_id, name) values ($1, $2, 'beep')`, [bot, owner]);
  await h.q(`insert into public.presence (user_id, status, last_seen, pref) values
    ($1, 'online', now(), null), ($2, 'online', now() - interval '30 seconds', null), ($3, 'idle', now(), null), ($4, 'dnd', now(), 'dnd'),
    ($5, 'online', now() - interval '10 minutes', null), ($6, 'online', now(), 'invisible'), ($7, 'online', now(), null), ($8, 'online', now(), null), ($9, 'online', now(), null)`,
    [owner, online, idle, dnd, gone, ghost, bot, outsider, mod]);
  await h.q(`insert into public.feature_flags (key, label, description, mode, servers, users) values ('live_badges', 'x', 'x', 'test', $1, '{}') on conflict (key) do update set mode = 'test', servers = excluded.servers`, [`{${sid}}`]);
  const role = (await h.one(`insert into public.roles (server_id, name, perms) values ($1, 'mods', '{"mention_everyone": true}') returning id`, [sid])).id;
  await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, mod, role]);
  const general = (await h.one(`insert into public.channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [sid])).id;
  const staff = (await h.one(`insert into public.channels (server_id, name, kind, private) values ($1, 'staff', 'text', true) returning id`, [sid])).id;
  await h.q(`insert into public.channel_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [staff, role, sid]);
  const elsewhere = (await h.one(`insert into public.channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [other])).id;

  const send = async (who, cid, content, extra = {}) => {
    await h.as(who);
    await h.q(`delete from public.sent`);
    const r = await h.one(`insert into public.messages (channel_id, author_id, content${extra.here_to ? ', here_to' : ''}) values ($1, $2, $3${extra.here_to ? ', $4' : ''}) returning id, content, here_to`,
      extra.here_to ? [cid, who, content, extra.here_to] : [cid, who, content]);
    await h.admin();
    return r;
  };
  const sorted = (a) => [...(a ?? [])].sort();

  // 1. The owner's @here reaches the online members only: not idle, dnd, offline, invisible, the bot or the author.
  let m = await send(owner, general, 'meeting now @here');
  h.eq('@here keeps its text for someone who may', m.content, 'meeting now @here');
  h.eq('online members only, no author, no bot', sorted(m.here_to), sorted([online, mod]));
  const notice = (await h.q(`select payload from public.sent where event = 'unread'`))[0]?.payload;
  h.eq('the live-badge notice is sent', !!notice, true);
  h.eq('the notice carries here_to', sorted(notice.here_to), sorted([online, mod]));
  h.eq('the notice does not call it @everyone', notice.everyone, false);

  // 2. The unread counters: a mention for the people reached, a plain unread for the others.
  await h.as(online);
  let c = await h.one(`select unread, mentions from public.unread_counts_for(array(select c from public.my_visible_server_channels() c)) where channel_id = $1`, [general]);
  h.eq('reached: counted as a mention', [c.unread, c.mentions], [1, 1]);
  c = await h.one(`select unread, mentions from public.unread_counts_v1() where channel_id = $1`, [general]);
  h.eq('unread_counts_v1 agrees', [c.unread, c.mentions], [1, 1]);
  await h.as(idle);
  c = await h.one(`select unread, mentions from public.unread_counts_for(array(select c from public.my_visible_server_channels() c)) where channel_id = $1`, [general]);
  h.eq('idle: unread but not a mention', [c.unread, c.mentions], [1, 0]);
  await h.admin();

  // 3. A plain member without mention_everyone: the @ gets a zero-width space and nobody is pinged.
  m = await send(online, general, 'hey @here look');
  h.eq('no permission: defused', m.content, `hey @${ZW}here look`);
  h.eq('no permission: nobody reached', m.here_to, null);
  const n2 = (await h.q(`select payload from public.sent where event = 'unread'`))[0]?.payload;
  h.eq('no permission: the notice carries nothing', n2.here_to ?? null, null);

  // 4. A role with the permission counts, like @everyone.
  m = await send(mod, general, '@here ready?');
  h.eq('a role with mention_everyone may @here', sorted(m.here_to), sorted([owner, online]));

  // 5. Not a ping: an email address, @here inside a word, a forwarded message, a message with no @here at all.
  m = await send(owner, general, 'mail me@here.com');
  h.eq('an email address is not @here', [m.content, m.here_to], ['mail me@here.com', null]);
  m = await send(owner, general, 'come @hereafter');
  h.eq('@hereafter is not @here', m.here_to, null);
  m = await send(owner, general, '↪ Forwarded\n@here');
  h.eq('a forwarded @here pings nobody again', m.here_to, null);
  m = await send(owner, general, 'nothing to see', { here_to: `{${online}}` });
  h.eq('here_to from the client is ignored', m.here_to, null);

  // 5b. The author cannot edit the list afterwards (the edit policy has no column list); editing the text keeps it.
  await h.as(mod);
  const kept = (await h.one(`select here_to from public.messages where content = '@here ready?'`)).here_to;
  await h.q(`update public.messages set here_to = $1 where content = '@here ready?'`, [`{${idle},${gone}}`]);
  h.eq('here_to cannot be edited', sorted((await h.one(`select here_to from public.messages where content = '@here ready?'`)).here_to), sorted(kept));
  await h.q(`update public.messages set content = 'ready? (edited)' where content = '@here ready?'`);
  h.eq('an edit keeps the list', sorted((await h.one(`select here_to from public.messages where content = 'ready? (edited)'`)).here_to), sorted(kept));
  await h.q(`delete from public.sent`);
  await h.q(`delete from public.messages where content = 'ready? (edited)'`);
  const del = (await h.q(`select payload from public.sent where event = 'unread'`))[0]?.payload;
  h.eq('a delete notice carries no list', [del?.operation, del?.here_to ?? null], ['DELETE', null]);
  await h.admin();

  // 6. A private channel: only the people who can see it (a legacy Manage Server role counts too).
  m = await send(owner, staff, '@here staff only');
  h.eq('private channel: role holders only', sorted(m.here_to), [mod]);
  const legacy = (await h.one(`insert into public.roles (server_id, name, manage_server) values ($1, 'old admins', true) returning id`, [sid])).id;
  await h.q(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, online, legacy]);
  m = await send(owner, staff, '@here staff again');
  h.eq('private channel: legacy Manage Server sees it', sorted(m.here_to), sorted([mod, online]));
  await h.q(`delete from public.member_roles where role_id = $1`, [legacy]);
  // 7. Channel overrides live (flag channel_perms on for the server): a channel-level view deny leaves only the owner.
  await h.q(`insert into public.feature_flags (key, label, description, mode, servers, users) values ('channel_perms', 'x', 'x', 'test', $1, '{}') on conflict (key) do update set mode = 'test', servers = excluded.servers`, [`{${sid}}`]);
  const hidden = (await h.one(`insert into public.channels (server_id, name, kind) values ($1, 'hidden', 'text') returning id`, [sid])).id;
  await h.q(`insert into public.channel_overrides (server_id, channel_id, deny) values ($1, $2, '{view_channel}')`, [sid, hidden]);
  m = await send(mod, hidden, '@here anyone?');
  h.eq('override deny: only who can see it', sorted(m.here_to), [owner]);
  await h.q(`update public.feature_flags set mode = 'off' where key = 'channel_perms'`);

  // 8. A banned member is skipped.
  await h.db.exec(`select set_config('test.banned', '${online}', false)`);
  m = await send(owner, general, '@here again');
  h.eq('a banned member is not pinged', sorted(m.here_to), [mod]);
  await h.db.exec(`select set_config('test.banned', '', false)`);

  // 9. Server not in the flag: plain text, no list, no zero-width space either.
  m = await send(online, elsewhere, 'yo @here');
  h.eq('flag off for the server: untouched', [m.content, m.here_to], ['yo @here', null]);

  // 10. A bot (yapper.bot) skips the permission test and still reaches the online members.
  await h.as(bot);
  await h.db.exec(`select set_config('yapper.bot', '1', false)`);
  m = await h.one(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'bot says @here') returning content, here_to`, [general, bot]);
  await h.db.exec(`select set_config('yapper.bot', '', false)`);
  await h.admin();
  h.eq('a bot may @here', sorted(m.here_to), sorted([owner, online, mod]));

  // 11. Nobody online: null, not an empty list.
  await h.q(`update public.presence set last_seen = now() - interval '1 hour' where user_id <> $1`, [owner]);
  m = await send(owner, general, '@here hello?');
  h.eq('nobody online: no list', m.here_to, null);
}
