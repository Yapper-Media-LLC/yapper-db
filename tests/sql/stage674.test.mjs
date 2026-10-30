// 674: flag raw_mentions (a row) and bot role pings like Discord: a bot with Mention @everyone in the channel pings any
// role that isn't automatic; webhooks, people posting as bots and bots without the permission keep the old rule.
// Stand-ins (PGlite stops at 024): roles.mentionable / auto / perms (044, 130), channel overrides (142), bots, the live
// server_perm_user and a channel_perm_of that honours a channel-level deny, and the two guards' bot lines as live.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '674_raw_mentions_bot_role_pings.sql'), 'utf8');
const ZW = '​';

const STANDINS = String.raw`
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[], users uuid[]);
alter table public.channels add column if not exists category_id uuid;
alter table public.roles add column if not exists mentionable boolean not null default false;
alter table public.roles add column if not exists auto text not null default 'none';
alter table public.roles add column if not exists perms jsonb not null default '{}'::jsonb;
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), channel_id uuid, category_id uuid, role_id uuid, allow text[] not null default '{}', deny text[] not null default '{}');
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (bot_id uuid, user_id uuid);
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select k = 'role_mentions' $$;
create or replace function public.legacy_manage_server(perm text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.is_bot_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bots b where b.id = uid) or exists (select 1 from public.bot_accounts a where a.user_id = uid) $$;
create or replace function public.server_perm_user(sid uuid, uid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = uid)
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
      where mr.server_id = sid and mr.user_id = uid
        and (coalesce((r.perms->>'administrator')::boolean, false) or (r.manage_server and public.legacy_manage_server(perm)) or coalesce((r.perms->>perm)::boolean, false))) $$;
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.channel_overrides o where o.channel_id = cid and o.role_id is null and perm = any(o.deny)) then false
              else coalesce(base, false) end $$;
create or replace function public.fix_role_pings_bot(cid uuid, body text) returns text language sql stable as $$ select body $$;
create table if not exists public.guard_out (content text);
create or replace function public.message_perm_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('yapper.bot', true) = '1' then new.content := public.fix_role_pings_bot(new.channel_id, new.content); return new; end if;
  return new;
end $$;
create or replace function public.message_edit_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.content is distinct from old.content and coalesce(current_setting('yapper.bot', true), '') = '1' then
    new.content := public.fix_role_pings_bot(old.channel_id, new.content);
  end if;
  return new;
end $$;
`;

export default async function (h) {
  for (const bad of ['drop ', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`674 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('674 runs', () => h.db.exec(MIG));
  await h.ok('674 re-runs cleanly', () => h.db.exec(MIG));

  const f = await h.one(`select mode, users::text[] u, servers::text[] s, description d from public.feature_flags where key = 'raw_mentions'`);
  h.eq('flag in test', f.mode, 'test');
  h.eq('flag: Antic', f.u.join(), '00000000-0000-4000-8000-00000000a001');
  h.eq('flag: Yapper HQ', f.s.join(), '00000000-0000-4000-8000-00000000b001');
  h.eq('flag: backslash kept as typed', f.d.includes('\\@user'), true);

  const guard = (await h.one(`select prosrc from pg_proc where proname = 'message_perm_guard'`)).prosrc;
  h.eq('send guard passes the author', guard.includes('fix_role_pings_bot(new.channel_id, new.content, new.author_id)'), true);
  const edit = (await h.one(`select prosrc from pg_proc where proname = 'message_edit_guard'`)).prosrc;
  h.eq('edit guard passes the author', edit.includes('fix_role_pings_bot(old.channel_id, new.content, old.author_id)'), true);
  h.eq('patched once', guard.split('new.author_id').length - 1, 1);

  const owner = await h.signup('owner@x.test', 'owner');
  const bot = await h.signup('bot@x.test', 'pingbot');
  const weak = await h.signup('weak@x.test', 'weakbot');
  const human = await h.signup('human@x.test', 'human');
  const house = await h.signup('star@x.test', 'starboard');
  await h.admin();
  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  const cid = (await h.one(`insert into public.channels (kind, name, server_id) values ('text', 'general', $1) returning id`, [sid])).id;
  const cid2 = (await h.one(`insert into public.channels (kind, name, server_id) values ('text', 'quiet', $1) returning id`, [sid])).id;
  await h.db.query(`insert into public.channel_overrides (channel_id, deny) values ($1, '{mention_everyone}')`, [cid2]);
  for (const u of [owner, bot, weak, human, house]) await h.db.query(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u]);
  await h.db.query(`insert into public.bots (id) values ($1), ($2)`, [bot, weak]);
  await h.db.query(`insert into public.bot_accounts (bot_id, user_id) values (gen_random_uuid(), $1)`, [house]);
  const role = async (name, mentionable, auto = 'none', perms = '{}') =>
    (await h.one(`insert into public.roles (server_id, name, mentionable, auto, perms) values ($1, $2, $3, $4, $5::jsonb) returning id`, [sid, name, mentionable, auto, perms])).id;
  const pingers = await role('Pingers', false, 'none', '{"mention_everyone": true}');
  const open = await role('Open', true);
  const closed = await role('Closed', false);
  const auto = await role('Everyone', true, 'everyone');
  await h.db.query(`insert into public.member_roles (server_id, user_id, role_id) values ($1, $2, $3), ($1, $4, $3), ($1, $5, $3)`, [sid, bot, pingers, human, house]);

  const fix = async (c, body, uid) => (await h.one(`select public.fix_role_pings_bot($1, $2, $3) t`, [c, body, uid])).t;
  const msg = `<@&${open}> <@&${closed}> <@&${auto}>`;
  h.eq('bot with the permission: open and closed ping, auto never', await fix(cid, msg, bot), `<@&${open}> <@&${closed}> @${ZW}Everyone`);
  h.eq('bot without it: only the open role', await fix(cid, msg, weak), `<@&${open}> @${ZW}Closed @${ZW}Everyone`);
  h.eq('channel denies Mention @everyone: old rule', await fix(cid2, msg, bot), `<@&${open}> @${ZW}Closed @${ZW}Everyone`);
  h.eq('not a bot (in-house post as a person): old rule', await fix(cid, msg, human), `<@&${open}> @${ZW}Closed @${ZW}Everyone`);
  h.eq('in-house account (starboard copies text): old rule', await fix(cid, msg, house), `<@&${open}> @${ZW}Closed @${ZW}Everyone`);
  h.eq('no author: old rule', await fix(cid, msg, null), `<@&${open}> @${ZW}Closed @${ZW}Everyone`);
  h.eq('two-argument form: old rule', (await h.one(`select public.fix_role_pings_bot($1, $2) t`, [cid, msg])).t, `<@&${open}> @${ZW}Closed @${ZW}Everyone`);
  await h.db.exec(`select set_config('yapper.webhook', '1', false)`);
  h.eq('webhook: old rule', await fix(cid, msg, bot), `<@&${open}> @${ZW}Closed @${ZW}Everyone`);
  await h.db.exec(`select set_config('yapper.webhook', '', false)`);
  await h.db.query(`delete from public.server_members where server_id = $1 and user_id = $2`, [sid, weak]);
  h.eq('a raw token is never touched', await fix(cid, `<\\@&${closed}>`, weak), `<\\@&${closed}>`);
  h.eq('other servers\' roles turn into text', await fix(cid, `<@&00000000-0000-0000-0000-000000000001>`, bot), `@${ZW}deleted-role`);
  const anon = await h.as(human).then(() => h.db.query(`select public.fix_role_pings_bot($1, $2, $3)`, [cid, msg, bot])).then(() => 'ran', () => 'refused');
  await h.admin();
  h.eq('people can\'t call it', anon, 'refused');
}
