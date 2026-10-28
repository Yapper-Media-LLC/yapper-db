// 460: security audit fixes. PGlite replays 001..024 only, so: flags (031, 041), stage298's stand-ins, then the few
// functions 460's bodies name that live in later migrations (channel_allows, channel_overrides_live, channel_perm,
// basic_perm) as stand-ins with the real server-wide rule for read_history (everyone_perms, like 044's server_perm),
// then 460 twice. Checks: the messages read policy, search v1 and bot_channel_history_ok all follow Read Message
// History; own messages still show; media_scans.etag exists.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage298.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const MORE = `
alter table public.roles add column if not exists perms jsonb not null default '{}'::jsonb;
create table if not exists public.media_scans (bucket text not null, path text not null, user_id uuid, score real, verdict text, primary key (bucket, path));
alter table public.servers add column if not exists everyone_perms jsonb not null default '{}'::jsonb;
create table if not exists public.bot_servers (bot_id uuid, server_id uuid);
create or replace function public.basic_perm(perm text) returns boolean language sql immutable as $$
  select perm in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis', 'create_invite',
                  'change_nickname', 'connect', 'speak', 'create_polls', 'read_history');
$$;
-- The server-wide answer (044 server_perm, the parts that matter here): owner yes, else every member unless everyone_perms says no.
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select sid is not null and (
    exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid() and coalesce((r.perms->>perm)::boolean, false))
    or (public.basic_perm(perm) and public.is_server_member(sid)
        and coalesce(((select everyone_perms from public.servers where id = sid)->>perm)::boolean, true)));
$$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select public.server_perm((select server_id from public.channels where id = cid), perm);
$$;
create or replace function public.channel_overrides_live(cid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select case when c.server_id is null then true else public.server_perm(c.server_id, perm) end from public.channels c where c.id = cid), true);
$$;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '460_security_audit_oct24.sql'), 'utf8');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'search'`);
  await h.ok('460 applies', () => h.db.exec(MIG));
  await h.ok('460 re-runs cleanly', () => h.db.exec(MIG));

  h.eq('media_scans.etag exists', (await h.one(
    `select count(*)::int n from information_schema.columns where table_name = 'media_scans' and column_name = 'etag'`)).n, 1);

  const owner = await h.signup('o@test.dev', 'owner');
  const member = await h.signup('m@test.dev', 'member');
  const bot = await h.signup('b@test.dev', 'bot');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, owner, member]);
  const cid = (await h.one(`insert into channels (server_id, name, kind, created_by) values ($1, 'general', 'text', $2) returning id`, [sid, owner])).id;
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', 'o:m', $1) returning id`, [owner])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [dm, owner, member]);
  // New-account slowmode: one message per author every 3 s, so the seed waits between rows (like stage409).
  const wait = () => new Promise((r) => setTimeout(r, 3200));
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hello from the owner')`, [cid, owner]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hello from the member')`, [cid, member]);
  await wait();
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hello dm')`, [dm, owner]);
  await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $2)`, [bot, sid]);

  const count = async (sql, params) => (await h.one(`select count(*)::int n from ${sql}`, params)).n;

  // History on (the default): everyone reads everything.
  await h.as(member);
  h.eq('history on: member reads the channel', await count(`messages where channel_id = $1`, [cid]), 2);
  h.eq('history on: search v1 finds both channel messages', await count(`search_messages('hello', $1)`, [sid]), 2);
  h.eq('history on: channel_history_ok says yes', (await h.one(`select channel_history_ok($1) ok`, [cid])).ok, true);

  // The owner turns Read Message History off for @everyone (the server-wide setting the UI exposes).
  await h.admin();
  await h.q(`update servers set everyone_perms = '{"read_history": false}' where id = $1`, [sid]);

  await h.as(member);
  h.eq('history off: channel_history_ok says no', (await h.one(`select channel_history_ok($1) ok`, [cid])).ok, false);
  h.eq('history off: only my own message comes back from a direct read', await count(`messages where channel_id = $1`, [cid]), 1);
  h.eq('history off: and it is mine', (await h.one(`select author_id from messages where channel_id = $1`, [cid])).author_id, member);
  h.eq('history off: search v1 skips the channel, DMs still searchable', await count(`search_messages('hello', $1)`, [sid]), 0);
  h.eq('history off: DM search unaffected', await count(`search_messages('hello')`), 1);
  h.eq('history off: DMs are never gated', (await h.one(`select channel_history_ok($1) ok`, [dm])).ok, true);
  await wait();
  await h.ok('history off: posting (insert ... returning) still works', () => h.q(
    `insert into messages (channel_id, author_id, content) values ($1, $2, 'still posting') returning id`, [cid, member]));

  // A moderator (Manage Messages through a role) still reads, so they can still delete what they see arrive live.
  await h.admin();
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, mod]);
  const rid = (await h.one(`insert into roles (server_id, name, perms) values ($1, 'Mod', '{"manage_messages": true}') returning id`, [sid])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, mod, rid]);
  await h.as(mod);
  h.eq('history off: a moderator still reads the channel', await count(`messages where channel_id = $1`, [cid]), 3);
  await h.as(owner);
  h.eq('history off: the owner still reads everything', await count(`messages where channel_id = $1`, [cid]), 3);
  h.eq('history off: owner search works', await count(`search_messages('hello', $1)`, [sid]), 2);

  // Bots: service role only, same rule.
  await h.admin();
  h.eq('bot: history off for everyone is off for the bot', (await h.one(`select bot_channel_history_ok($1, $2) ok`, [bot, cid])).ok, false);
  h.eq('bot: DMs are never gated by history (visibility is checked before)', (await h.one(`select bot_channel_history_ok($1, $2) ok`, [bot, dm])).ok, true);
  h.eq('bot: unknown channel is a no', (await h.one(`select bot_channel_history_ok($1, gen_random_uuid()) ok`, [bot])).ok, false);
  await h.q(`update servers set everyone_perms = '{}' where id = $1`, [sid]);
  h.eq('bot: history on again', (await h.one(`select bot_channel_history_ok($1, $2) ok`, [bot, cid])).ok, true);
  await h.q(`delete from bot_servers where bot_id = $1`, [bot]);
  h.eq('bot: not in the server, no history', (await h.one(`select bot_channel_history_ok($1, $2) ok`, [bot, cid])).ok, false);
  await h.as(member);
  await h.fails('bot functions are not callable by people', `select bot_channel_history_ok($1, $2)`, [bot, cid]);
  await h.fails('bot_server_perm is not callable by people', `select bot_server_perm($1, $2, 'read_history')`, [bot, sid]);
}
