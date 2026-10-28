// 378: bug fixes (21 Oct): my_mentions lists replies to my messages, invite_card ignores letter case, import_discord_server
// names channels like create_channel, bad_name sees words glued to digits, reorder_roles says when it would skip a role.
// Starts from stage 24 with stand-ins for what these functions lean on. The OLD versions (the live text of Oct 21, or the
// migration that holds it) are installed first so each bug is shown to exist, then 378 is applied twice. The slur filter
// text comes out of the migration files (has_slur_plain from 325, bad_name from 156), and the test word is read out of that
// regex at run time, so this file does not spell any slur.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('378_bug_fixes_1021.sql');
const cut = (src, from, to, keepTo = false) => { const i = src.indexOf(from); const j = src.indexOf(to, i + from.length); if (i < 0 || j < 0) throw new Error(`cut: ${from} not found`); return src.slice(i, j + (keepTo ? to.length : 0)); };

const m325 = mig('325_filter_and_bot_check_fixes.sql');
const HAS_SLUR_PLAIN = cut(m325, 'create or replace function public.has_slur_plain', '$function$;', true);
const BAD_NAME_OLD = cut(mig('156_sexual_spam.sql'), 'create or replace function public.bad_name', '$$;', true);
const FANCY = cut(mig('146_role_mentions_fancy_names.sql'), 'create or replace function public.fancy_clean_name', 'create or replace function public.channel_fancy_name');
const REORDER_OLD = mig('186_reorder_roles_rank.sql');
// A word the boundary-anchored list of has_slur_plain matches as a whole word, taken from the regex itself.
const WORD = (HAS_SLUR_PLAIN.match(/\|((?:[a-z]\+){3,})s\*/) ?? [])[1]?.replace(/\+/g, '');
if (!WORD) throw new Error('could not read a test word out of has_slur_plain');

const STANDINS = String.raw`
set check_function_bodies = off;
create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$ select t $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable set search_path = public as $$ select normalize(coalesce(t, ''), NFKC) $$;
create or replace function public.six_nine_g(t text) returns text language plpgsql immutable set search_path = public as $$
declare s text := regexp_replace(public.fold_fancy(coalesce(t, '')),
    '(?<![[:alnum:]])([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|[0-9a-fA-F]{20,})(?![[:alnum:]])', ' ', 'g');
  n int := 0;
begin
  while n < 8 and s ~ '[[:alpha:]][69]+[[:alpha:]]' loop
    s := regexp_replace(s, '(?<=[[:alpha:]])[69](?=[69]*[[:alpha:]])', 'g', 'g');
    n := n + 1;
  end loop;
  return s;
end $$;
create or replace function public.slur_text(t text) returns text language sql immutable set search_path to 'public', 'extensions' as $function$
  select regexp_replace(
    regexp_replace(
      translate(lower(unaccent(regexp_replace(public.fold_fancy(t), '[​-‏⁠﻿­]', '', 'g'))), '0134578@$!|', 'oieastbasii'),
      '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g');
$function$;
create or replace function public.has_slur(t text) returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select public.has_slur_plain(t)
    or (
      (coalesce(t, '') ~ '[[:alpha:]][69]+[[:alpha:]]'
        or (coalesce(t, '') ~ '[^\x01-\x7f]' and public.fold_fancy(t) ~ '[[:alpha:]][69]+[[:alpha:]]'))
      and public.has_slur_plain(public.six_nine_g(t))
    )
    or (
      strpos(coalesce(t, ''), chr(8238)) > 0
      and (public.has_slur_plain(reverse(t)) or public.has_slur_plain(public.six_nine_g(reverse(t))))
    );
$function$;
create or replace function public.no_bad_names() returns trigger language plpgsql set search_path to 'public', 'extensions' as $function$
declare col text; val text; was text;
begin
  foreach col in array tg_argv loop
    val := to_jsonb(new) ->> col;
    was := case when tg_op = 'UPDATE' then to_jsonb(old) ->> col else null end;
    if val is not null and (was is null or lower(val) <> lower(was)) and public.bad_name(val) then
      raise exception 'That name isn''t allowed on Yapper. Pick another.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end; $function$;
-- the slur filter text the live database has (has_slur_plain from 325, bad_name from 156), then the live trigger on names
${HAS_SLUR_PLAIN}
${BAD_NAME_OLD}
create trigger profiles_no_bad_names before insert or update of username on public.profiles for each row execute function public.no_bad_names('username');

-- feature flags, as live
create table if not exists public.feature_flags (key text primary key, label text not null default '', description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path to 'public' as $function$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false);
$function$;
insert into public.feature_flags (key, mode) values ('discord_import', 'everyone'), ('fancy_names', 'everyone') on conflict (key) do update set mode = excluded.mode;

-- columns and helpers the functions read
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.servers add column if not exists description text;
alter table public.servers add column if not exists banner_path text;
alter table public.servers add column if not exists banner_x numeric;
alter table public.servers add column if not exists banner_y numeric;
alter table public.servers add column if not exists banner_zoom numeric;
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists category_id uuid;
create table if not exists public.channel_categories (id uuid primary key default gen_random_uuid(), server_id uuid not null references public.servers (id) on delete cascade,
  name text not null, position int not null default 0);
alter table public.invites drop constraint if exists invites_code_check;   -- live allows vanity codes (letters, digits, - and _, up to 32)
create table if not exists public.presence (user_id uuid primary key, last_seen timestamptz not null default now());
create or replace function public.is_staff() returns boolean language sql stable as $$ select false $$;
create or replace function public.my_role_pings() returns table(sid uuid, pats text[]) language sql stable as $$ select null::uuid, null::text[] where false $$;
create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable security definer set search_path = public as $$
  select c.* from public.channels c join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid() where c.server_id is not null $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
      or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                 where mr.server_id = sid and mr.user_id = auth.uid()
                   and (coalesce((r.perms->>'administrator')::boolean, false) or coalesce((r.perms->>perm)::boolean, false))) $$;
alter table public.messages disable trigger messages_raid_guard;
alter table public.messages disable trigger messages_slowmode;
alter table public.messages disable trigger messages_defaults;   -- (it stamps created_at := now(); the test needs older messages)

-- the live text-channel name functions (slugify_channel as live, the fancy ones as migration 146 has them)
create or replace function public.slugify_channel(n text) returns text language sql immutable set search_path to 'public', 'extensions' as $function$
  select left(nullif(regexp_replace(regexp_replace(lower(btrim(n)), '\s+', '-', 'g'), '[^[:alnum:]_\-☀-➿️‍\U0001F300-\U0001FAFF]', '', 'g'), ''), 100);
$function$;
${FANCY}

-- OLD (live, Oct 21) my_mentions: no reply branch
CREATE OR REPLACE FUNCTION public.my_mentions(lim integer DEFAULT 40)
 RETURNS SETOF messages LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  with pings as materialized (select * from public.my_role_pings()),
  chans as materialized (
    select cm.channel_id, null::uuid as sid, cm.joined_at as since
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where cm.user_id = (select auth.uid()) and not public.is_site_banned((select auth.uid()))
    union all
    select v.id, v.server_id, sm.joined_at
    from public.my_visible_server_channels() v
    join public.server_members sm on sm.server_id = v.server_id and sm.user_id = (select auth.uid())
    where not exists (select 1 from public.servers sd where sd.id = v.server_id and sd.shut_down_at is not null and not public.is_staff())
  )
  select m.*
  from chans
  left join pings p on p.sid = chans.sid
  cross join lateral (
    select x.* from public.messages x
    where x.channel_id = chans.channel_id
      and (strpos(x.content, '<@') > 0 or strpos(x.content, '@everyone') > 0)
      and x.created_at > greatest(now() - interval '30 days', coalesce(chans.since, now() - interval '30 days'))
      and x.author_id <> (select auth.uid())
      and (x.content like '%<@' || (select auth.uid())::text || '>%'
           or x.content ~ '(^|[^\w])@everyone([^\w]|$)'
           or (p.pats is not null and strpos(x.content, '<@&') > 0 and x.content like any (p.pats)))
    order by x.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  ) m
  order by m.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$function$;
revoke all on function public.my_mentions(integer) from public, anon;
grant execute on function public.my_mentions(integer) to authenticated, service_role;

-- OLD (live, Oct 21) invite_card: case sensitive
CREATE OR REPLACE FUNCTION public.invite_card(invite_code text)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'server_id', s.id, 'name', s.name, 'icon_path', s.icon_path,
    'banner_path', s.banner_path, 'banner_x', s.banner_x, 'banner_y', s.banner_y, 'banner_zoom', s.banner_zoom,
    'created_at', s.created_at,
    'member_count', (select count(*) from public.server_members m where m.server_id = s.id),
    'online_count', (select count(*) from public.server_members m join public.presence p on p.user_id = m.user_id
                     where m.server_id = s.id and p.last_seen > now() - interval '100 seconds'),
    'already_member', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid())
  )
  from public.invites i join public.servers s on s.id = i.server_id
  where i.code = invite_code;
$function$;
revoke all on function public.invite_card(text) from public;
grant execute on function public.invite_card(text) to anon, authenticated, service_role;

-- OLD (live, Oct 21) import_discord_server: slugify_channel only
CREATE OR REPLACE FUNCTION public.import_discord_server(p jsonb)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare me uuid := auth.uid(); sid uuid; c jsonb; r jsonb; e jsonb; n int := 0; cats jsonb := '{}'::jsonb; cid uuid; pos int := 0;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('discord_import', null) then raise exception 'Importing isn''t open yet'; end if;
  perform public.check_icon_path(p->>'icon_path');
  if (select count(*) from public.servers where owner_id = me) >= 50 then raise exception 'You own a lot of servers already'; end if;
  insert into public.servers (name, icon_path, owner_id, description) values (left(btrim(p->>'name'), 100), p->>'icon_path', me, left(coalesce(p->>'description', ''), 300)) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  for c in select * from jsonb_array_elements(coalesce(p->'categories', '[]'::jsonb)) loop
    begin
      insert into public.channel_categories (server_id, name, position) values (sid, left(btrim(coalesce(c->>'name', '')), 40), coalesce((c->>'position')::int, n)) returning id into cid;
    exception when others then -- refused name: fallback name
      insert into public.channel_categories (server_id, name, position) values (sid, 'category', coalesce((c->>'position')::int, n)) returning id into cid;
    end;
    cats := cats || jsonb_build_object(c->>'key', cid);
    n := n + 1;
    exit when n >= 50;
  end loop;
  n := 0;
  for c in select * from jsonb_array_elements(coalesce(p->'channels', '[]'::jsonb)) loop
    begin
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end,
                case when c->>'kind' = 'voice' then left(c->>'name', 100) else coalesce(public.slugify_channel(c->>'name'), 'channel') end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    exception when check_violation or raise_exception then -- refused name: fallback name
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end, case when c->>'kind' = 'voice' then 'Voice' else 'channel' end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    end;
    n := n + 1;
    exit when n >= 100;
  end loop;
  if n = 0 then insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0); end if;
  n := 0;
  for r in select * from jsonb_array_elements(coalesce(p->'roles', '[]'::jsonb)) loop
    insert into public.roles (server_id, name, color, position, perms)
      values (sid, left(r->>'name', 32), nullif(r->>'color', ''), coalesce((r->>'position')::int, n), coalesce(r->'perms', '{}'::jsonb));
    n := n + 1;
    exit when n >= 50;
  end loop;
  n := 0;
  for e in select * from jsonb_array_elements(coalesce(p->'emojis', '[]'::jsonb)) loop
    begin
      insert into public.emojis (owner_id, server_id, name, path, animated) values (me, sid, e->>'name', e->>'path', coalesce((e->>'animated')::boolean, false));
      n := n + 1;
    exception when others then null; -- one bad emoji (name clash, unscanned) shouldn't sink the import
    end;
    exit when n >= 50;
  end loop;
  return sid;
end; $function$;
revoke all on function public.import_discord_server(jsonb) from public, anon;
grant execute on function public.import_discord_server(jsonb) to authenticated, service_role;
`;

/** The error message a statement throws, or '' if it worked. */
async function msg(h, sql, params = []) {
  try { await h.db.query(sql, params); return ''; } catch (e) { return String(e.message); }
}
const arr = (ids) => `{${ids.join(',')}}`;                        // a uuid[] literal
const sorted = (o) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : 1)));
const acl = async (h, fn) => (await h.q(`select grantee from information_schema.routine_privileges where routine_name = $1 and grantee in ('anon','authenticated','service_role','PUBLIC') order by 1`, [fn])).map((r) => r.grantee);

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(REORDER_OLD);

  const amy = await h.signup('amy378@test.dev', 'amy378');
  const bob = await h.signup('bob378@test.dev', 'bob378');
  const cat = await h.signup('cat378@test.dev', 'cat378');
  const dan = await h.signup('dan378@test.dev', 'dan378');   // outsider
  await h.admin();
  const mk = {
    server: async (name, owner, members) => {
      const s = (await h.one(`insert into servers (name, owner_id) values ($1, $2) returning id`, [name, owner])).id;
      for (const m of [owner, ...members]) await h.q(`insert into server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '1 year') on conflict do nothing`, [s, m]);
      return s;
    },
    channel: async (s, name) => (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', $1, $2, $3) returning id`, [name, s, amy])).id,
    msg: async (ch, who, content, { reply, ago = 0 } = {}) =>
      (await h.one(`insert into messages (channel_id, author_id, content, reply_to_id, created_at) values ($1, $2, $3, $4, now() - ($5 || ' minutes')::interval) returning id`,
        [ch, who, content, reply ?? null, String(ago)])).id,
  };
  const FANCY = '┃・┃';   // a name made only of fancy symbols: nothing is left of it after slugify_channel
  const BOLD = '\u{1D5E3}\u{1D5E5}\u{1D5E2}';
  const imported = async (who, names) => {
    await h.as(who);
    const id = (await h.one(`select import_discord_server($1::jsonb) id`, [JSON.stringify({ name: 'Imported', channels: names.map((n) => (typeof n === 'string' ? { kind: 'text', name: n } : n)) })])).id;
    await h.admin();
    return (await h.q(`select name, kind from channels where server_id = $1 order by position, name`, [id])).map((r) => `${r.kind}:${r.name}`);
  };

  // ---------- data for 1 and 2, created while the OLD functions are installed ----------
  const S1 = await mk.server('mentions', amy, [bob, cat]);
  const ch1 = await mk.channel(S1, 'general');
  const A1 = await mk.msg(ch1, amy, 'my question', { ago: 100 });
  const B1 = await mk.msg(ch1, bob, 'an answer', { reply: A1, ago: 90 });             // reply to me, no ping
  const C1 = await mk.msg(ch1, cat, 'side chat', { reply: B1, ago: 80 });             // reply to bob, not me
  const A2 = await mk.msg(ch1, amy, 'following up', { reply: A1, ago: 70 });          // my own reply
  const B2 = await mk.msg(ch1, bob, `hey <@${amy}> look`, { ago: 60 });               // a ping
  const C2 = await mk.msg(ch1, cat, `<@${amy}> thanks`, { reply: A1, ago: 50 });      // a ping AND a reply to me: listed once
  const OLD = await mk.msg(ch1, bob, 'very late answer', { reply: A1, ago: 60 * 24 * 40 }); // 40 days ago: outside the 30 days
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', 'dm378', $1) returning id`, [amy])).id;   // a DM: my message, their reply
  await h.q(`insert into channel_members (channel_id, user_id, joined_at) values ($1, $2, now() - interval '1 year'), ($1, $3, now() - interval '1 year')`, [dm, amy, bob]);
  const D1 = await mk.msg(dm, amy, 'dm hello', { ago: 40 });
  const D2 = await mk.msg(dm, bob, 'dm answer', { reply: D1, ago: 30 });
  const S2 = await mk.server('left later', bob, [amy, cat]);                           // a reply to me there stops showing once I leave
  const ch2 = await mk.channel(S2, 'general');
  const A3 = await mk.msg(ch2, amy, 'question two', { ago: 20 });
  const B3 = await mk.msg(ch2, bob, 'answer two', { reply: A3, ago: 10 });
  await h.q(`insert into invites (code, server_id, created_by) values ('AbCd12', $1, $2), ('My-Cool_Server', $1, $2)`, [S1, amy]);

  const mentions = async (who, lim = 40) => { await h.as(who); return (await h.q(`select id from my_mentions($1) order by created_at desc, id`, [lim])).map((r) => r.id); };
  const card = async (c) => (await h.one(`select invite_card($1) r`, [c])).r;

  // ---------- the OLD behaviour, so each bug is seen before 378 ----------
  h.eq('OLD my_mentions: pings only, the replies to me are missing (the bug)', await mentions(amy), [C2, B2]);
  await h.as(bob);
  h.eq('OLD invite_card: the code only works exactly as stored', [(await card('AbCd12'))?.server_id, await card('abcd12'), await card('ABCD12')], [S1, null, null]);
  h.eq('OLD import_discord_server: a symbol-only channel name collapses to "channel"', await imported(amy, [FANCY, 'My Channel!']), ['text:channel', 'text:my-channel']);

  // ---------- apply 378, twice ----------
  await h.admin();
  await h.ok('378 applies', () => h.db.exec(MIG));
  await h.ok('378 re-runs cleanly', () => h.db.exec(MIG));

  // ============================== 1. my_mentions ==============================
  const now5 = await mentions(amy);
  h.eq('every reply to me and every ping, newest first, each once', now5, [B3, D2, C2, B2, B1]);
  h.eq('the ping that is also a reply is listed once', now5.filter((x) => x === C2).length, 1);
  h.eq('my own reply to my own message is not listed', now5.includes(A2), false);
  h.eq('a reply to somebody else is not listed', now5.includes(C1), false);
  h.eq('a reply older than 30 days is not listed', now5.includes(OLD), false);
  // Parity with the @ badge: the rule unread_counts_for uses (reply_to_id is a message of mine, written by someone else),
  // limited to channels I can see and the last 30 days, gives exactly the reply rows of the inbox.
  await h.as(amy);
  const badgeRule = (await h.q(`select f.id from messages f
      where f.author_id <> auth.uid() and f.created_at > now() - interval '30 days'
        and f.reply_to_id is not null
        and exists (select 1 from messages pm where pm.id = f.reply_to_id and pm.author_id = auth.uid())
        and f.channel_id in (select id from my_visible_server_channels() union select channel_id from channel_members where user_id = auth.uid())`)).map((r) => r.id);
  h.eq('the inbox lists everything the badge rule counts', badgeRule.every((x) => now5.includes(x)), true);
  h.eq('...which are exactly B3, D2, C2, B1', [...badgeRule].sort(), [B3, D2, C2, B1].sort());
  h.eq('bob: the only reply to him is C1', await mentions(bob), [C1]);
  h.eq('lim 1 gives the newest only', await mentions(amy, 1), [B3]);
  await h.as(amy);
  h.eq('lim 0 gives one row, lim null gives the default', [(await h.one(`select count(*)::int n from my_mentions(0)`)).n, (await h.one(`select count(*)::int n from my_mentions(null)`)).n], [1, 5]);
  h.eq('an outsider sees nothing', await mentions(dan), []);
  // leaving a server hides its replies; rejoining later keeps what came before the join hidden (same rule as pings)
  await h.admin();
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [S2, amy]);
  h.eq('after leaving the server its reply is gone', await mentions(amy), [D2, C2, B2, B1]);
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id, joined_at) values ($1, $2, now())`, [S2, amy]);
  h.eq('rejoining later: replies from before the join stay hidden', await mentions(amy), [D2, C2, B2, B1]);
  // the reply branch looks at my newest 500 messages of the last 30 days
  await h.admin();
  await h.q(`insert into messages (channel_id, author_id, content, created_at)
             select $1, $2, 'filler ' || g, now() - (g || ' seconds')::interval from generate_series(1, 505) g`, [ch1, amy]);
  const newest = (await h.one(`select id from messages where author_id = $1 and content = 'filler 1'`, [amy])).id;
  const oldest = (await h.one(`select id from messages where author_id = $1 and content = 'filler 505'`, [amy])).id;
  const R_NEW = await mk.msg(ch1, cat, 'reply to my newest', { reply: newest });
  const R_OLD = await mk.msg(ch1, cat, 'reply to my 505th newest', { reply: oldest });
  const got = await mentions(amy, 100);
  h.eq('a reply to one of my newest 500 is listed', got.includes(R_NEW), true);
  h.eq('known limit: a reply to my 501st newest message in 30 days is not', got.includes(R_OLD), false);
  // permissions are the old ones
  await h.as(null);
  await h.fails('anon cannot call my_mentions', `select * from my_mentions(5)`);
  await h.admin();
  h.eq('my_mentions is still security definer and stable', await h.one(`select prosecdef, provolatile from pg_proc where proname = 'my_mentions'`), { prosecdef: true, provolatile: 's' });
  h.eq('my_mentions ACL: authenticated and service_role only', await acl(h, 'my_mentions'), ['authenticated', 'service_role']);

  // ============================== 2. invite_card ==============================
  await h.as(bob);
  h.eq('exact case still works', (await card('AbCd12'))?.server_id, S1);
  h.eq('lower case works', (await card('abcd12'))?.server_id, S1);
  h.eq('upper case works', (await card('ABCD12'))?.server_id, S1);
  h.eq('a vanity-style code works however it is typed', [(await card('my-cool_server'))?.server_id, (await card('MY-COOL_SERVER'))?.server_id], [S1, S1]);
  h.eq('an unknown code gives null', await card('nope99'), null);
  h.eq('member count and already_member are filled', [(await card('abcd12')).member_count, (await card('abcd12')).already_member], [3, true]);
  await h.as(dan);
  h.eq('an outsider is not already_member', (await card('ABCD12')).already_member, false);
  await h.as(null);
  h.eq('anon can still read an invite card', (await h.one(`select invite_card('aBcD12') r`)).r?.server_id, S1);
  await h.admin();
  h.eq('invite_card ACL: anon, authenticated, service_role', await acl(h, 'invite_card'), ['anon', 'authenticated', 'service_role']);

  // ============================== 3. import_discord_server ==============================
  // With the new code, fancy_names on: the fancy name stays, ASCII names slug like before, voice keeps its text, nothing usable becomes "channel".
  h.eq('fancy_names on: symbol names stay, ascii names slug, voice is kept, empty ones fall back',
    await imported(amy, [FANCY, 'My Channel!', { kind: 'voice', name: 'Hang Out' }, '---', '']),
    [`text:${FANCY}`, 'text:my-channel', 'voice:Hang Out', 'text:channel', 'text:channel']);
  h.eq('fancy_names on: other fancy letters stay too', (await imported(amy, [BOLD])).length, 1);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'fancy_names'`);
  h.eq('fancy_names off: the old slugify branch, like create_channel', await imported(amy, [FANCY, 'My Channel!']), ['text:channel', 'text:my-channel']);
  await h.q(`update feature_flags set mode = 'test', users = array[$1]::uuid[] where key = 'fancy_names'`, [amy]);
  h.eq('fancy_names in test mode follows create_channel: on for a tester', (await imported(amy, [FANCY]))[0], `text:${FANCY}`);
  h.eq('...off for everybody else', (await imported(bob, [FANCY]))[0], 'text:channel');
  await h.q(`update feature_flags set mode = 'everyone' where key = 'fancy_names'`);
  h.eq('no channels at all still makes #general', await imported(amy, []), ['text:general']);
  await h.as(null);
  await h.fails('anon cannot import', `select import_discord_server('{}'::jsonb)`);
  await h.as(amy);
  await h.q(`select set_config('request.jwt.claim.sub', '', false)`);
  h.eq('not signed in is refused', /Not signed in/.test(await msg(h, `select import_discord_server('{}'::jsonb)`)), true);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'discord_import'`);
  await h.as(amy);
  h.eq('import switched off is still refused', /isn't open yet/.test(await msg(h, `select import_discord_server('{}'::jsonb)`)), true);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'discord_import'`);
  h.eq('import_discord_server ACL unchanged', await acl(h, 'import_discord_server'), ['authenticated', 'service_role']);

  // ============================== 4. bad_name ==============================
  await h.admin();
  const bad = async (t) => (await h.one(`select bad_name($1) r`, [t])).r;
  const plain = async (t) => (await h.one(`select bad_name_plain($1) r`, [t])).r;
  const defOf = async (sig) => (await h.one(`select pg_get_functiondef('${sig}'::regprocedure) d`)).d;
  h.eq('bad_name_plain is still the old body after two runs (no wrapper inside it)', /bad_name/.test((await defOf('public.bad_name_plain(text)')).replace('public.bad_name_plain(t text)', '')), false);
  h.eq('bad_name wraps it', /bad_name_plain/.test(await defOf('public.bad_name(text)')), true);
  // the old rules still hold
  h.eq('a listed word on its own is caught, as before', [await bad(WORD), await plain(WORD)], [true, true]);
  h.eq('a word from the second list is caught', [await bad('sexy'), await plain('sexy')], [true, true]);
  // the fix: words glued to digits. The old body lets every one of these through.
  const padded = [`1111${WORD}1111`, `${WORD}1`, `1${WORD}`, `0${WORD}8`, `${WORD}123`, `777${WORD}`, `_1111${WORD}1111_`, `xx 1111${WORD}1111`, `${WORD}1337 fan`,
    `１１１１${WORD}１１１１`, `1111${WORD.toUpperCase()}1111`, '1111sexy1111', 'sexy1', '3sexy3', '_1111sexy1111_', 'cool 0sexy0'];
  for (const t of padded) h.eq(`old body misses, bad_name catches: ${t.replace(WORD, 'W').replace(WORD.toUpperCase(), 'W')}`, [await plain(t), await bad(t)], [false, true]);
  // digits between the letters of the word: every digit taken off
  h.eq('digits stuffed between the letters are caught', await bad(WORD.split('').join('3')), true);
  // ordinary names stay fine, in both
  for (const ok of ['user123', 'dave2008', 'x_y_z', 'Scunthorpe', 'Scunthorpe2008', 'Class1', 'Sussex99', 'assassin1', 'Cassandra4', 'Bob_the_builder_2', 'night_owl_88',
    'Minecraft Server 24/7', 'Hello 2020', 'R2D2', 'C3P0', 'cp3', '123456', '1111', 'abc', 'Gam3rs', 'N1ght Owl', 'coonhound7', 'Class of 2008', 'xX_pro_Xx', '', 'a1', '42']) {
    h.eq(`still fine: ${JSON.stringify(ok)}`, [await bad(ok), await plain(ok)], [false, false]);
  }
  h.eq('two letters and digits are not enough to refuse (cp3), a bare cp still is', [await bad('cp3'), await bad('cp')], [false, true]);
  h.eq('null gives what it gave before', [await bad(null), await bad('')], [await plain(null), await plain('')]);
  // the real path: usernames go through the no_bad_names trigger
  const signup = (email, name) => msg(h, `insert into auth.users (email, raw_user_meta_data) values ($1, $2::jsonb)`, [email, JSON.stringify({ username: name })]);
  h.eq('a digit-padded banned username is refused at signup', /isn't allowed/.test(await signup('pad378@test.dev', `1111${WORD}1111`)), true);
  h.eq('a clean username with digits signs up', await signup('ok378@test.dev', 'dave2008'), '');
  // grants: same as the old bad_name
  h.eq('bad_name ACL: authenticated and service_role', await acl(h, 'bad_name'), ['authenticated', 'service_role']);
  h.eq('bad_name_plain ACL: the same', await acl(h, 'bad_name_plain'), ['authenticated', 'service_role']);
  await h.as(null);
  await h.fails('anon cannot call bad_name', `select bad_name('x')`);
  await h.as(amy);
  h.eq('a signed-in user can', (await h.one(`select bad_name('x') r`)).r, false);

  // ============================== 5. reorder_roles ==============================
  await h.admin();
  const owner = await h.signup('own378@test.dev', 'owner378');
  const mod = await h.signup('mod378@test.dev', 'mod378');
  const adm = await h.signup('adm378@test.dev', 'adm378');
  const plainUser = await h.signup('plain378@test.dev', 'plain378');
  await h.admin();
  const SR = await mk.server('roles', owner, [mod, adm, plainUser]);
  const SX = await mk.server('other roles', owner, []);
  const role = async (name, position, perms = {}, server = SR) => (await h.one(`insert into roles (server_id, name, position, perms) values ($1, $2, $3, $4::jsonb) returning id`, [server, name, position, JSON.stringify(perms)])).id;
  const T1 = await role('Tie1', 8);
  const T2 = await role('Tie2', 8);
  const BOSS = await role('Boss', 6);
  const MOD = await role('Mod', 4, { manage_roles: true });
  const ADM = await role('Adm', 4, { administrator: true });
  const HELP = await role('Helper', 3);
  const NEW = await role('Newbie', 2);
  const GUEST = await role('Guest', 1);
  const FOREIGN = await role('Foreign', 0, {}, SX);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3), ($1, $4, $5)`, [SR, mod, MOD, adm, ADM]);
  const pos = async () => Object.fromEntries((await h.q(`select name, position from roles where server_id = $1 order by name`, [SR])).map((r) => [r.name, r.position]));
  const reorder = async (who, order) => { await h.as(who); return msg(h, `select reorder_roles($1, $2::text::uuid[])`, [SR, arr(order)]); };
  const TOP = 'You can only move roles below your own top role';
  const start = await pos();

  // The OLD function (186) on a copy that 378 did not touch: swapping Boss and Mod (above my own top role) is accepted and does nothing.
  await h.db.exec(REORDER_OLD.replace(/public\.reorder_roles/g, 'public.reorder_roles_old'));
  await h.as(mod);
  h.eq('OLD reorder_roles: a move above your own top role is accepted without a word...', await msg(h, `select reorder_roles_old($1, $2::text::uuid[])`, [SR, arr([T1, T2, MOD, BOSS, ADM, HELP, NEW, GUEST])]), '');
  h.eq('...and nothing changed (the page springs back)', await pos(), start);

  // the new one: this is what the Roles page sends, every role top first
  h.eq('a move of roles below my top role, with the whole list sent, works', await reorder(mod, [T1, T2, BOSS, MOD, ADM, NEW, GUEST, HELP]), '');
  h.eq('...Helper, Newbie, Guest took each other\'s places', { h: (await pos()).Helper, n: (await pos()).Newbie, g: (await pos()).Guest }, { h: 1, n: 3, g: 2 });
  h.eq('the roles above me did not move', { t1: (await pos()).Tie1, boss: (await pos()).Boss, mod: (await pos()).Mod }, { t1: 8, boss: 6, mod: 4 });
  h.eq('equal positions above me may come in either order', await reorder(mod, [T2, T1, BOSS, MOD, ADM, HELP, NEW, GUEST]), '');
  h.eq('sending only the roles below me works', await reorder(mod, [GUEST, NEW, HELP]), '');
  h.eq('duplicates and another server\'s role are ignored', await reorder(mod, [T1, T2, BOSS, MOD, ADM, HELP, HELP, FOREIGN, NEW, GUEST]), '');
  const settled = await pos();

  // refusals: a role at or above my top role moved, or a lower one put above it
  for (const [what, order] of [
    ['a role below put above my top role', [T1, T2, BOSS, NEW, MOD, ADM, HELP, GUEST]],
    ['my own top role moved down', [T1, T2, BOSS, HELP, MOD, ADM, NEW, GUEST]],
    ['a role above me swapped with another above me', [T1, T2, MOD, BOSS, ADM, HELP, NEW, GUEST]],
    ['a role below put at the very top', [GUEST, T1, T2, BOSS, MOD, ADM, HELP, NEW]],
    ['the whole list reversed', [GUEST, NEW, HELP, ADM, MOD, BOSS, T2, T1]],
    ['only roles at or above me, reordered', [BOSS, T1]],
    ['only roles at or above me, left as they are', [T1, BOSS]],
    ['a list with nothing of this server in it', [FOREIGN]],
    ['an empty list', []],
  ]) {
    h.eq(`refused with a clear message: ${what}`, await reorder(mod, order), TOP);
    h.eq('...and nothing moved', await pos(), settled);
  }

  // administrator is bound by the same rule; no Manage Roles at all is refused as before
  h.eq('administrator permission: below its top role works', await reorder(adm, [T1, T2, BOSS, MOD, ADM, NEW, HELP, GUEST]), '');
  h.eq('administrator permission: above its top role is refused', await reorder(adm, [T1, T2, BOSS, HELP, MOD, ADM, NEW, GUEST]), TOP);
  h.eq('no Manage Roles: refused as before', await reorder(plainUser, [HELP, NEW]), 'You need Manage Roles to rearrange roles');
  h.eq('not a member of the server at all: refused as before', await reorder(dan, [HELP, NEW]), 'You need Manage Roles to rearrange roles');
  await h.as(null);
  await h.fails('anon cannot call reorder_roles', `select reorder_roles($1, $2::text::uuid[])`, [SR, arr([HELP])]);
  await h.admin();
  await h.q(`select set_config('request.jwt.claim.sub', '', false)`);
  h.eq('nobody signed in: "Sign in first"', /Sign in first/.test(await msg(h, `select reorder_roles($1, $2::text::uuid[])`, [SR, arr([HELP])])), true);

  // the owner is unchanged: anything goes, in the order given (top first)
  h.eq('the owner can put any role anywhere', await reorder(owner, [GUEST, NEW, HELP, MOD, ADM, BOSS, T1, T2]), '');
  h.eq('...exactly in the order sent', await pos(), sorted({ Guest: 7, Newbie: 6, Helper: 5, Mod: 4, Adm: 3, Boss: 2, Tie1: 1, Tie2: 0 }));
  h.eq('another server\'s role is untouched by the owner\'s reorder', (await h.one(`select position from roles where id = $1`, [FOREIGN])).position, 0);
  await h.admin();
  h.eq('reorder_roles ACL unchanged', await acl(h, 'reorder_roles'), ['authenticated', 'service_role']);

  // ============================== what 378 replaces ==============================
  h.eq('replaced functions keep their security mode (bad_name stays invoker)',
    (await h.q(`select proname, prosecdef from pg_proc where pronamespace = 'public'::regnamespace and proname in ('my_mentions','invite_card','import_discord_server','bad_name','reorder_roles') order by 1`)).map((r) => `${r.proname}:${r.prosecdef}`),
    ['bad_name:false', 'import_discord_server:true', 'invite_card:true', 'my_mentions:true', 'reorder_roles:true']);
  h.eq('every replaced function keeps its search_path setting',
    (await h.q(`select proname from pg_proc where pronamespace = 'public'::regnamespace and proname in ('my_mentions','invite_card','import_discord_server','bad_name','bad_name_plain','reorder_roles')
                  and not exists (select 1 from unnest(proconfig) c where c like 'search_path=%') order by 1`)), []);
}
