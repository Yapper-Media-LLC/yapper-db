// 603: thread permissions (create_threads, send_in_threads, manage_threads).
// The live functions need many later helpers, so the stand-ins are cut down but carry the exact lines 603 patches
// (copied from the live text, Oct 27), and channel_allows reads a small table so each check can be flipped.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '603_thread_perms.sql'), 'utf8');

const STANDINS = String.raw`

create or replace function public.basic_perm(perm text) returns boolean language sql immutable set search_path to 'public', 'extensions' as $$
  select perm in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis', 'create_invite',
                  'change_nickname', 'connect', 'speak', 'create_polls', 'read_history', 'send_voice_messages', 'use_headings');
$$;
create table if not exists public.t603_ch (id uuid primary key, server_id uuid, kind text, parent_id uuid, locked boolean default false);
create table if not exists public.t603_deny (channel_id uuid, perm text);
create table if not exists public.t603_srv (perm text);
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable as $$
  select not exists (select 1 from public.t603_deny d where d.channel_id = cid and d.perm = channel_allows.perm)
    and (public.basic_perm(perm) or exists (select 1 from public.t603_srv s where s.perm = channel_allows.perm)) $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable as $$
  select public.basic_perm(perm) or exists (select 1 from public.t603_srv s where s.perm = server_perm.perm) $$;
create or replace function public.can_access_channel(cid uuid) returns boolean language sql stable as $$ select true $$;
create table if not exists public.channel_overrides (id bigserial primary key, channel_id uuid, allow text[] not null default '{}', deny text[] not null default '{}',
  constraint channel_overrides_known_perms check (allow <@ array['view_channel','send_messages','add_reactions','attach_files','embed_links','mention_everyone','manage_messages','read_history','connect','speak','send_voice_messages','use_headings']::text[]
    and deny <@ array['view_channel','send_messages','add_reactions','attach_files','embed_links','mention_everyone','manage_messages','read_history','connect','speak','send_voice_messages','use_headings']::text[]));

create or replace function public.can_post_channel(cid uuid) returns boolean language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if exists (select 1 from public.t603_ch t where t.id = cid and t.kind = 'forum') then return false; end if;
  if exists (select 1 from public.channels t where t.id = cid and t.kind = 'thread' and t.locked /* forums_v2: locked, not closed */
             and not public.channel_allows(t.parent_id, 'manage_messages') and not public.server_perm(t.server_id, 'manage_channels')) then return false; end if;
  cid := coalesce((select ch.parent_id from public.channels ch where ch.id = cid), cid);
  return public.channel_allows(cid, 'send_messages');
end $function$;

create or replace function public.create_thread(p_parent uuid, p_title text, p_tags text[] default '{}', p_message uuid default null, p_content text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare me uuid := gen_random_uuid(); p public.channels;
begin
  select * into p from public.channels where id = p_parent;
  if p.kind = 'forum' then
    if not public.channel_allows(p.id, 'send_messages') then raise exception 'You can''t post here'; end if;
  elsif not public.can_post_channel(p.id) then
    raise exception 'You can''t post here';
  end if;
  if public.server_timed_out(p.server_id, me) is not null then raise exception 'You''re timed out in this server'; end if;
  return gen_random_uuid();
end $function$;

create or replace function public.server_timed_out(sid uuid, uid uuid) returns timestamptz language sql stable as $$ select null::timestamptz $$;
alter table public.roles add column if not exists auto text;
alter table public.roles add column if not exists perms jsonb;
alter table public.roles add column if not exists manage_server boolean;
alter table public.roles add column if not exists manage_messages boolean;
alter table public.channel_overrides add column if not exists role_id uuid;
create table if not exists public.server_bots (server_id uuid, bot text, config jsonb);
create or replace function public.onboarding_role_ok(sid uuid, rid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

create or replace function public.thread_mod(p_thread uuid) returns boolean language plpgsql stable security definer set search_path to 'public' as $function$
declare t public.channels;
begin
  select * into t from public.channels where id = p_thread and kind = 'thread';
  if not found or not public.can_access_channel(t.id) then return false; end if;
  return public.channel_allows(t.parent_id, 'manage_messages') or public.server_perm(t.server_id, 'manage_channels');
end $function$;

create or replace function public.forum_mod(p_forum uuid) returns boolean language plpgsql stable security definer set search_path to 'public' as $function$
declare f public.channels;
begin
  select * into f from public.channels where id = p_forum;
  if not found or f.server_id is null or not public.can_access_channel(f.id) then return false; end if;
  return public.channel_allows(f.id, 'manage_messages') or public.server_perm(f.server_id, 'manage_channels');
end $function$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`603 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  // The stand-ins read public.channels: give it the columns 593 added.
  await h.db.exec(`alter table public.channels add column if not exists parent_id uuid;
    alter table public.channels add column if not exists locked boolean not null default false;
    alter table public.channels drop constraint if exists channels_kind_check;`);
  await h.db.exec(STANDINS);
  await h.ok('603 runs', () => h.db.exec(MIG));
  await h.ok('603 re-runs cleanly', () => h.db.exec(MIG));

  h.eq('create_threads is everyday', (await h.one(`select basic_perm('create_threads') v`)).v, true);
  h.eq('send_in_threads is everyday', (await h.one(`select basic_perm('send_in_threads') v`)).v, true);
  h.eq('manage_threads is not', (await h.one(`select basic_perm('manage_threads') v`)).v, false);
  h.eq('old keys stay everyday', (await h.one(`select basic_perm('use_headings') and basic_perm('send_messages') v`)).v, true);

  await h.ok('an override can deny create_threads', () => h.q(`insert into channel_overrides (deny) values ('{create_threads,send_in_threads}')`));
  await h.ok('an override can allow manage_threads', () => h.q(`insert into channel_overrides (allow) values ('{manage_threads}')`));
  await h.fails('unknown keys are still refused', `insert into channel_overrides (allow) values ('{fly}')`);

  const owner = await h.signup('o@x.com', 'owner');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  const text = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [S])).id;
  const thread = (await h.one(`insert into channels (server_id, name, kind, parent_id) values ($1, 't', 'thread', $2) returning id`, [S, text])).id;
  const deny = (perm) => h.q(`insert into t603_deny values ($1, $2)`, [text, perm]);
  const undeny = () => h.q(`update t603_deny set perm = 'x' where channel_id = $1`, [text]);
  const post = async (cid) => (await h.one(`select can_post_channel($1) v`, [cid])).v;

  await h.ok('a thread starts with everything on', () => h.q(`select create_thread($1, 'hi')`, [text]));
  h.eq('and takes replies', await post(thread), true);
  await deny('create_threads');
  await h.fails('create_threads denied on the channel: no new threads', `select create_thread($1, 'hi')`, [text]);
  h.eq('...existing threads still take replies', await post(thread), true);
  await undeny();
  await deny('send_in_threads');
  h.eq('send_in_threads denied: no replies in its threads', await post(thread), false);
  h.eq('...the channel itself still takes messages', await post(text), true);
  await undeny();

  await h.q(`update channels set locked = true where id = $1`, [thread]);
  h.eq('a locked thread refuses members', await post(thread), false);
  await h.q(`insert into t603_srv values ('manage_threads')`);
  h.eq('Manage Threads posts in a locked thread', await post(thread), true);
  h.eq('Manage Threads moderates threads', (await h.one(`select thread_mod($1) v`, [thread])).v, true);
  h.eq('...and forums', (await h.one(`select forum_mod($1) v`, [text])).v, true);
  await h.q(`update t603_srv set perm = 'x'`);
  h.eq('without it (and no Manage Messages / Channels) no moderation', (await h.one(`select thread_mod($1) v`, [thread])).v, false);
  await h.q(`insert into t603_srv values ('manage_messages')`);
  h.eq('Manage Messages still moderates threads like before', (await h.one(`select thread_mod($1) v`, [thread])).v, true);

  // Onboarding (251): everyday thread keys are fine, a Manage Threads override is mod power.
  const role = async (perms) => (await h.one(`insert into roles (server_id, name, perms) values ($1, 'r', $2) returning id`, [S, perms])).id;
  const ok = async (rid) => (await h.one(`select onboarding_role_ok($1, $2) v`, [S, rid])).v;
  h.eq('a role with the thread keys can be handed out', await ok(await role({ create_threads: true, send_in_threads: true, use_headings: true })), true);
  h.eq('a role with Manage Threads is refused', await ok(await role({ manage_threads: true })), false);
  const plain = await role({ send_messages: true });
  await h.q(`insert into channel_overrides (channel_id, role_id, allow) values ($1, $2, '{manage_threads}')`, [text, plain]);
  h.eq('nor one with a Manage Threads override', await ok(plain), false);
}
