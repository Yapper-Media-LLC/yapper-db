// 686: channel overrides take the three thread keys, and onboarding takes plain roles with Use Big Text / thread keys.
// channel_overrides gets the live (pre-603) CHECK, onboarding_role_ok the live body, so the migration replaces real text.
// 603 then runs on top, to show the two stay compatible in either order.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '686_override_thread_keys_onboarding.sql'), 'utf8');
const M603 = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '603_thread_perms.sql'), 'utf8');

const OLD = `array['view_channel', 'send_messages', 'add_reactions', 'attach_files', 'embed_links', 'mention_everyone', 'manage_messages', 'read_history', 'connect', 'speak', 'send_voice_messages', 'use_headings']::text[]`;
const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists auto text;
alter table public.roles add column if not exists manage_server boolean default false;
alter table public.roles add column if not exists manage_messages boolean default false;
create table if not exists public.server_bots (server_id uuid, bot text, config jsonb);
create table if not exists public.channel_overrides (
  id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid, category_id uuid, role_id uuid,
  allow text[] not null default '{}', deny text[] not null default '{}',
  constraint channel_overrides_known_perms check (allow <@ ${OLD} and deny <@ ${OLD}));
create or replace function public.onboarding_role_ok(sid uuid, rid uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select exists (
    select 1 from public.roles r
    where r.id = rid and r.server_id = sid and coalesce(r.auto, 'none') = 'none'
      and not coalesce(r.manage_server, false) and not coalesce(r.manage_messages, false)
      and not exists (select 1 from jsonb_each_text(coalesce(r.perms, '{}'::jsonb)) p(k, v)
        where v <> 'false' and k not in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis',
          'create_invite', 'change_nickname', 'connect', 'speak', 'create_polls', 'read_history', 'send_voice_messages', 'view_channel'))
      and not exists (select 1 from public.channel_overrides co
        where co.role_id = r.id and co.allow && array['manage_messages', 'mention_everyone', 'manage_channels', 'manage_roles']::text[])
      and not exists (select 1 from public.server_bots b
        where b.server_id = sid and b.bot = 'tickets' and strpos(coalesce(b.config::text, ''), r.id::text) > 0));
$function$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`686 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  const owner = await h.signup('own686@x.test', 'own686');
  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('s686', $1) returning id`, [owner])).id;
  const role = async (name, perms) => (await h.one(`insert into public.roles (server_id, name, perms) values ($1, $2, $3) returning id`, [sid, name, perms])).id;
  const ok = async (rid) => (await h.one(`select public.onboarding_role_ok($1, $2) v`, [sid, rid])).v;
  const save = (allow, deny = []) => h.db.query(`insert into public.channel_overrides (server_id, channel_id, allow, deny) values ($1, gen_random_uuid(), $2, $3)`, [sid, allow, deny]);
  const fails = async (f) => { try { await f(); return false; } catch { return true; } };

  const bigText = await role('member', { send_messages: true, use_headings: true, create_threads: true, send_in_threads: true });
  h.eq('before: plain role with Big Text and thread keys counts as admin (the bug)', await ok(bigText), false);
  h.eq('before: thread keys refused by the CHECK (the bug)', await fails(() => save(['create_threads', 'send_in_threads', 'manage_threads'])), true);

  await h.ok('686 runs', () => h.db.exec(MIG));
  await h.ok('686 re-runs cleanly', () => h.db.exec(MIG));

  h.eq('thread keys save as allow', await fails(() => save(['create_threads', 'send_in_threads', 'manage_threads'])), false);
  h.eq('thread keys save as deny', await fails(() => save([], ['create_threads', 'send_in_threads', 'manage_threads'])), false);
  h.eq('every editor key saves', await fails(() => save(['view_channel', 'send_messages', 'add_reactions', 'attach_files', 'embed_links', 'mention_everyone', 'manage_messages', 'read_history', 'connect', 'speak', 'send_voice_messages', 'use_headings'])), false);
  h.eq('unknown key still refused', await fails(() => save(['administrator'])), true);
  h.eq('unknown deny key still refused', await fails(() => save([], ['ban_members'])), true);

  h.eq('plain role with Big Text and thread keys: ok for onboarding', await ok(bigText), true);
  h.eq('plain role, keys set false: ok', await ok(await role('quiet', { manage_threads: false, kick_members: 'false' })), true);
  h.eq('Manage Threads role perm: refused', await ok(await role('threadmod', { send_messages: true, manage_threads: true })), false);
  h.eq('Kick Members: refused', await ok(await role('kicker', { kick_members: true })), false);
  const ovRole = await role('ov', { send_messages: true });
  await h.db.query(`insert into public.channel_overrides (server_id, channel_id, role_id, allow) values ($1, gen_random_uuid(), $2, '{manage_threads}')`, [sid, ovRole]);
  h.eq('Manage Threads channel override: refused', await ok(ovRole), false);
  const msgRole = await role('msg', {});
  await h.db.query(`update public.roles set manage_messages = true where id = $1`, [msgRole]);
  h.eq('manage_messages column: refused', await ok(msgRole), false);

  // 603 after 686: its onboarding patches and its CHECK step see 686's text and skip. (Its other patches need the
  // live thread functions, which stage603 covers with its own stand-ins.)
  const M603_PART = M603.slice(M603.indexOf('create or replace function pg_temp.patch_fn'), M603.indexOf('-- 3.'))
    + M603.slice(M603.indexOf('-- 6.'));
  const before = (await h.one(`select prosrc from pg_proc where proname = 'onboarding_role_ok'`)).prosrc;
  await h.ok('603 (onboarding + CHECK steps) runs after 686', () => h.db.exec(M603_PART));
  h.eq('603 leaves onboarding_role_ok as 686 wrote it', (await h.one(`select prosrc from pg_proc where proname = 'onboarding_role_ok'`)).prosrc, before);
  h.eq('one CHECK, still with the thread keys', (await h.one(`select count(*)::int n from pg_constraint where conname = 'channel_overrides_known_perms' and pg_get_constraintdef(oid) like '%manage_threads%'`)).n, 1);
  await h.ok('686 re-runs after 603', () => h.db.exec(MIG));
}
