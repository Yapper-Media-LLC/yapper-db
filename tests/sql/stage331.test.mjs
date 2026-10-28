// 331: taken-down servers closed to reads (can_access_channel, my_mentions, search_messages_v2), promote channel invite
// checks, reactions refused for timed-out / very limited accounts, username hold message.
// Starts from stage 24. The migration patches LIVE functions by exact line (no migration file has their live text), so
// the stand-ins below are reduced copies of the live functions that keep the lines the migration looks for. The patch
// itself, the new tables/functions/trigger and the refusals are what is tested here, not the rest of those functions.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '331_takedown_reads_promo_reactions.sql'), 'utf8');

const STANDINS = String.raw`
set check_function_bodies = off;
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.profiles add column if not exists muted_until timestamptz;
create table if not exists public.server_timeouts (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  until timestamptz not null,
  primary key (server_id, user_id)
);
create table if not exists public.post_marks (
  channel_id uuid not null, author_id uuid not null, kind text not null, at timestamptz not null default now(),
  primary key (channel_id, author_id, kind)
);
create table if not exists public.username_holds (name_key text primary key, user_id uuid not null, until timestamptz not null);
-- Test knobs: test.staff = '1' makes is_staff() true; test_tier holds a standing tier per user.
create or replace function public.is_staff() returns boolean language sql stable as $$ select coalesce(current_setting('test.staff', true), '') = '1' $$;
create table public.test_tier (user_id uuid primary key, tier text not null);
create or replace function public.standing_tier(uid uuid) returns text language sql stable as $$ select coalesce((select tier from public.test_tier where user_id = uid), 'good') $$;
-- The 024 raid guard is not what is tested here.
alter table public.messages disable trigger messages_raid_guard;

-- Reduced copies of the live functions (Oct 21). The lines the migration patches are exactly as live.
CREATE OR REPLACE FUNCTION public.can_access_channel(cid uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select
    not public.is_site_banned(auth.uid())
    and (
      public.is_channel_member(cid)
      or exists (
        select 1 from public.channels c
        where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
          and not c.private
      )
    );
$function$;

CREATE OR REPLACE FUNCTION public.my_mentions(lim integer DEFAULT 40)
 RETURNS SETOF messages LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  with chans as materialized (
    select cm.channel_id, null::uuid as sid, cm.joined_at as since
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where cm.user_id = (select auth.uid()) and not public.is_site_banned((select auth.uid()))
    union all
    select v.id, v.server_id, sm.joined_at
    from public.channels v
    join public.server_members sm on sm.server_id = v.server_id and sm.user_id = (select auth.uid())
  )
  select m.*
  from chans
  cross join lateral (
    select x.* from public.messages x
    where x.channel_id = chans.channel_id
      and (strpos(x.content, '<@') > 0 or strpos(x.content, '@everyone') > 0)
      and x.author_id <> (select auth.uid())
      and (x.content like '%<@' || (select auth.uid())::text || '>%'
           or x.content ~ '(^|[^\w])@everyone([^\w]|$)')
    order by x.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  ) m
  order by m.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$function$;

CREATE OR REPLACE FUNCTION public.search_messages_v2(q text, sid uuid DEFAULT NULL::uuid, cid uuid DEFAULT NULL::uuid, author uuid DEFAULT NULL::uuid, before timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS SETOF messages LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  chans uuid[];
begin
  if auth.uid() is null or public.is_site_banned(auth.uid()) then
    return;
  end if;
  select coalesce(array_agg(x.id), '{}') into chans from (
    select c.id
    from public.channels c
    where (cid is null or c.id = cid)
      and c.server_id is not null and public.is_server_member(c.server_id)
  ) x;
  if cardinality(chans) = 0 then
    return;
  end if;
  return query
    select m.* from public.messages m
    where m.channel_id = any(chans) and m.content ilike '%' || q || '%'
    order by m.created_at desc
    limit 50;
end;
$function$;

CREATE OR REPLACE FUNCTION public.standing_guard(action text, sid uuid DEFAULT NULL::uuid, other uuid DEFAULT NULL::uuid)
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare me uuid := auth.uid(); tier text; why text;
begin
  if me is null then return; end if;
  if public.is_staff() then return; end if;
  tier := public.standing_tier(me);
  if tier = 'good' then return; end if;
  why := ' See Settings → My Account → Account standing.';
  if tier = 'suspended' then
    raise exception 'Your account is suspended: you can read but not post or join.%', why using errcode = 'insufficient_privilege';
  end if;
  if tier = 'very_limited' and action in ('message_dm', 'dm_open', 'friend', 'join', 'create_server') then
    raise exception 'Your account is very limited: you can only read and reply in servers you are already in.%', why using errcode = 'insufficient_privilege';
  end if;
  if action = 'link' then
    raise exception 'Your account is limited: links are turned off for now.%', why using errcode = 'insufficient_privilege';
  end if;
end $function$;

-- What the live not_site_banned does for reactions (it calls standing_guard('react')).
create or replace function public.test_react_standing() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and coalesce(current_setting('yapper.bot', true), '') <> '1' then perform public.standing_guard('react'); end if;
  return new;
end $$;
create trigger reactions_standing_test before insert on public.reactions for each row execute function public.test_react_standing();

CREATE OR REPLACE FUNCTION public.username_holds_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  k_new text := lower(new.username);
  k_old text;
begin
  if tg_op = 'INSERT' then
    if exists (select 1 from public.username_holds h where h.name_key = k_new and h.until > now() and h.user_id <> new.id) then
      raise exception 'That username is taken' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  k_old := lower(old.username);
  if k_new is not distinct from k_old then return new; end if;
  if exists (select 1 from public.username_holds h where h.name_key = k_new and h.until > now() and h.user_id <> new.id) then
    raise exception 'That username is taken' using errcode = 'check_violation';
  end if;
  update public.username_holds set until = now() where name_key = k_new and user_id = new.id and until > now();
  insert into public.username_holds (name_key, user_id, until) values (k_old, new.id, now() + interval '7 days')
    on conflict (name_key) do update set user_id = excluded.user_id, until = excluded.until;
  return new;
end $function$;
create trigger profiles_username_holds before insert or update of username on public.profiles for each row execute function public.username_holds_guard();

-- The live promote trigger, as a stub the migration replaces (the trigger exists live already).
create or replace function public.invites_only_in_promo() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger messages_invites_only_in_promo before insert or update of content on public.messages for each row execute function public.invites_only_in_promo();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);

  const a = await h.signup('owner@test.dev', 'owner');
  const b = await h.signup('member@test.dev', 'member');
  const c = await h.signup('other@test.dev', 'other');
  const d = await h.signup('fourth@test.dev', 'fourth');
  await h.admin();

  // Act as a user while keeping full table rights (RLS is not what is tested here), and the test knobs.
  const act = async (uid) => { await h.admin(); await h.db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [uid ?? '']); };
  const knob = async (k, v) => h.db.query(`select set_config($1, $2, false)`, [k, v]);
  const err = async (sql, params = []) => { try { await h.db.query(sql, params); return null; } catch (e) { return e; } };
  const msg = async (ch, who, content) => (await h.one(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3) returning id`, [ch, who, content])).id;
  const server = async (name, owner, members) => {
    const s = (await h.one(`insert into public.servers (name, owner_id) values ($1, $2) returning id`, [name, owner])).id;
    for (const m of [owner, ...members]) await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [s, m]);
    return s;
  };
  const channel = async (s, name) => (await h.one(`insert into public.channels (kind, name, server_id, created_by) values ('text', $1, $2, $3) returning id`, [name, s, a])).id;

  const S1 = await server('taken down', a, [b, c]);
  const S2 = await server('fine', a, [b, c]);
  const ch1 = await channel(S1, 'general');
  const ch2 = await channel(S2, 'general');
  await msg(ch1, a, `hello <@${b}> in the closed one`);
  await msg(ch1, a, '@everyone closed secret');
  await msg(ch2, a, `hello <@${b}> in the open one`);
  await msg(ch2, a, '@everyone open news');

  // ----- a live function that has the line twice (or none) stops the migration, with its name -----
  const CAN = STANDINS.slice(STANDINS.indexOf('CREATE OR REPLACE FUNCTION public.can_access_channel'), STANDINS.indexOf('CREATE OR REPLACE FUNCTION public.my_mentions'));
  const stop = async () => { try { await h.db.exec(MIG); return ''; } catch (e) { return e.message; } };
  await h.db.exec(CAN.replace('select\n    not public.is_site_banned', `-- where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)\n  select\n    not public.is_site_banned`));
  h.eq('the line twice in a live function stops the migration', /can_access_channel\(uuid\) changed: expected the line to patch 1 time\(s\), found 2/.test(await stop()), true);
  await h.db.exec(CAN);

  // ----- the migration applies, and again -----
  await h.ok('331 applies', () => h.db.exec(MIG));
  await h.ok('331 re-runs cleanly', () => h.db.exec(MIG));
  const defOf = async (sig) => (await h.one(`select pg_get_functiondef('${sig}'::regprocedure) as d`)).d;
  const count = (hay, needle) => hay.split(needle).length - 1;
  h.eq('can_access_channel patched once after two runs', count(await defOf('public.can_access_channel(uuid)'), 'sd.shut_down_at'), 1);
  h.eq('my_mentions patched once', count(await defOf('public.my_mentions(integer)'), 'sd.shut_down_at'), 1);
  h.eq('search_messages_v2 patched once', count(await defOf('public.search_messages_v2(text, uuid, uuid, uuid, timestamp with time zone)'), 'sd.shut_down_at'), 1);
  h.eq('standing_guard patched once', count(await defOf('public.standing_guard(text, uuid, uuid)'), "'create_server', 'react')"), 1);
  h.eq('patched functions stay security definer', (await h.q(`select proname, prosecdef from pg_proc where proname in ('can_access_channel','my_mentions','search_messages_v2','standing_guard','username_holds_guard','invites_only_in_promo','reaction_guard') order by 1`)).map((r) => r.prosecdef), [true, true, true, true, true, true, true]);

  // ----- 1. taken-down servers -----
  await act(b);
  h.eq('before takedown: member reads the channel', (await h.one(`select can_access_channel($1) as ok`, [ch1])).ok, true);
  h.eq('before takedown: both pings show', (await h.q(`select content from my_mentions(40) where channel_id = $1`, [ch1])).length, 2);
  h.eq('before takedown: search finds it', (await h.q(`select id from search_messages_v2('secret')`)).length, 1);
  await h.admin();
  await h.q(`update public.servers set shut_down_at = now() where id = $1`, [S1]);
  await act(b);
  h.eq('taken down: member can no longer read the channel', (await h.one(`select can_access_channel($1) as ok`, [ch1])).ok, false);
  h.eq('taken down: its pings are gone from the inbox', (await h.q(`select id from my_mentions(40) where channel_id = $1`, [ch1])).length, 0);
  h.eq('taken down: the open server pings still show', (await h.q(`select id from my_mentions(40) where channel_id = $1`, [ch2])).length, 2);
  h.eq('taken down: search finds nothing in it', (await h.q(`select id from search_messages_v2('secret')`)).length, 0);
  h.eq('taken down: search still finds the open server', (await h.q(`select id from search_messages_v2('news')`)).length, 1);
  h.eq('the open server is unaffected', (await h.one(`select can_access_channel($1) as ok`, [ch2])).ok, true);
  await knob('test.staff', '1');
  h.eq('taken down: staff still read it (moderation)', (await h.one(`select can_access_channel($1) as ok`, [ch1])).ok, true);
  h.eq('taken down: staff search still reaches it', (await h.q(`select id from search_messages_v2('secret')`)).length, 1);
  await knob('test.staff', '');
  await h.admin();
  await h.q(`update public.servers set shut_down_at = null where id = $1`, [S1]);
  await act(b);
  h.eq('restored: readable again', (await h.one(`select can_access_channel($1) as ok`, [ch1])).ok, true);

  // ----- anchor guard: a changed live function stops the migration instead of doing nothing -----
  await h.admin();
  await h.db.exec(`CREATE OR REPLACE FUNCTION public.search_messages_v2(q text, sid uuid DEFAULT NULL::uuid, cid uuid DEFAULT NULL::uuid, author uuid DEFAULT NULL::uuid, before timestamp with time zone DEFAULT NULL::timestamp with time zone)
    RETURNS SETOF messages LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$ select m.* from public.messages m where false $f$;`);
  h.eq('a function whose line moved stops the migration, with its name', /search_messages_v2.* changed: expected the line to patch 1 time\(s\), found 0/.test(await stop()), true);
  // Put the patched copy back (the reduced live text, then the migration again).
  await h.db.exec(STANDINS.slice(STANDINS.indexOf('CREATE OR REPLACE FUNCTION public.search_messages_v2'), STANDINS.indexOf('CREATE OR REPLACE FUNCTION public.standing_guard')));
  await h.ok('331 applies again once the function matches', () => h.db.exec(MIG));

  // ----- 2. promote channel -----
  const HQ = await server('hq', a, [b, c, d]);
  const promo = await channel(HQ, 'promote-your-server');
  const general = await channel(HQ, 'general');
  await h.q(`update public.app_settings set default_server_id = $1`, [HQ]);
  const SA = await server('promoted', b, [c, d]);   // b, c, d are in it
  const SB = await server('closed promo', b, [c]);
  await h.q(`update public.servers set shut_down_at = now() where id = $1`, [SB]);
  await h.q(`insert into public.invites (code, server_id, created_by) values ('abcA12', $1, $2), ('abcB12', $3, $2)`, [SA, b, SB]);
  const link = (code) => `come join https://yapper.website/invite/${code} it is fun`;

  await act(b);
  const first = await msg(promo, b, link('abcA12'));
  h.eq('promote: a member posts a real invite to their live server', true, !!first);
  h.eq('promote: the server is marked', (await h.q(`select server_id from public.promo_invite_marks`)).map((r) => r.server_id), [SA]);
  await act(c);
  let e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, c, link('abcA12')]);
  h.eq('promote: a second account can not promote the same server inside 6 hours', /already promoted/.test(e?.message ?? ''), true);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, c, link('ABCA12')]);
  h.eq('promote: the invite code is matched without case', /already promoted/.test(e?.message ?? ''), true);
  await act(d);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, d, 'join https://yapper.website/invite/nope9999']);
  h.eq('promote: an invite that does not exist is refused', /doesn't work/.test(e?.message ?? ''), true);
  await act(a);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, a, link('abcA12')]);
  h.eq('promote: someone who is not in that server is refused', /only promote a server you are in/.test(e?.message ?? ''), true);
  await act(c);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, c, link('abcB12')]);
  h.eq('promote: a taken-down server can not be promoted', /can't be promoted/.test(e?.message ?? ''), true);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [general, c, link('abcA12')]);
  h.eq('promote: links still only go in the promote channel', /only go in #promote-your-server/.test(e?.message ?? ''), true);
  // Discord links keep the per-person limit only.
  await h.ok('promote: a Discord invite from someone who has not posted is fine', () => msg(promo, c, 'https://discord.gg/abc123'));
  await act(c);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, c, 'again https://discord.gg/zzz999']);
  h.eq('promote: the same person is still held to once every 6 hours', /once every 6 hours/.test(e?.message ?? ''), true);
  await act(b);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, b, 'also https://discord.gg/yyy888']);
  h.eq('promote: posting your own earlier server again is held to the person limit too', /once every 6 hours/.test(e?.message ?? ''), true);
  // Editing the text around an invite that is already posted is not a new promotion.
  await h.ok('promote: editing around the same link is fine', () => h.q(`update public.messages set content = content || ' (edited)' where id = $1`, [first]));
  // Staff skip it.
  await act(a);
  await knob('test.staff', '1');
  await h.ok('promote: staff can post anything', () => msg(promo, a, link('abcB12')));
  await knob('test.staff', '');
  // Another server is untouched.
  await act(b);
  await h.ok('promote: invites in other servers are not checked', () => msg(ch2, b, link('abcB12')));
  // After 6 hours the server can be promoted again by anyone in it.
  await h.admin();
  await h.q(`update public.promo_invite_marks set at = now() - interval '7 hours'`);
  await h.q(`update public.post_marks set at = now() - interval '7 hours'`);
  // (created_at can't be moved on a message, so the old promo posts are removed instead.)
  await h.q(`delete from public.messages where channel_id = $1`, [promo]);
  await act(d);
  await h.ok('promote: after 6 hours the server can be promoted again', () => msg(promo, d, link('abcA12')));
  h.eq('promote: the mark is fresh again', (await h.one(`select (at > now() - interval '1 minute') as fresh from public.promo_invite_marks where server_id = $1`, [SA])).fresh, true);

  // Links the checks can't read are refused, several invites in one post are each checked, and the server lock is taken.
  await h.admin();
  const SC = await server('multi c', b, [c]);
  const SD = await server('multi d', b, [c]);
  const SE = await server('lock e', a, []);
  await h.q(`insert into public.invites (code, server_id, created_by) values ('abcC12', $1, $2), ('abcD12', $3, $2), ('abcE12', $4, $5)`, [SC, b, SD, SE, a]);
  await act(d);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, d, 'join https://yapper.website/invite/%61bcC12']);
  h.eq('promote: a link with an encoded code is refused, not waved through', /doesn't work/.test(e?.message ?? ''), true);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, d, 'join https://yapper.website/invite/ and paste the code']);
  h.eq('promote: a link with no code is refused', /doesn't work/.test(e?.message ?? ''), true);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, d, `two: ${link('abcA12')} https://yapper.website/invite/nope9999`]);
  h.eq('promote: one good invite and one that does not exist is refused', /doesn't work/.test(e?.message ?? ''), true);
  await act(c);
  await h.ok('promote: two live servers in one post are fine', () => msg(promo, c, `both: https://yapper.website/invite/abcC12, https://yapper.website/invite/abcD12.`));
  h.eq('promote: both are marked', (await h.q(`select server_id from public.promo_invite_marks where server_id = any($1::uuid[]) order by 1`, [[SC, SD]])).length, 2);
  await act(b);
  e = await err(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, b, link('abcD12')]);
  h.eq('promote: the second one of that post counts as promoted for others', /already promoted/.test(e?.message ?? ''), true);
  await act(a);
  await h.db.exec('begin');
  await h.q(`insert into public.messages (channel_id, author_id, content) values ($1, $2, $3)`, [promo, a, link('abcE12')]);
  h.eq('promote: the per-server lock is taken while checking', (await h.one(`select count(*)::int as n from pg_locks where locktype = 'advisory'`)).n >= 1, true);
  await h.db.exec('rollback');

  // ----- 3. reactions -----
  await h.admin();
  const m2 = await msg(ch2, a, 'react to me');
  const dm = (await h.one(`insert into public.channels (kind, dm_key) values ('dm', 'x:y') returning id`)).id;
  await h.q(`insert into public.channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, b, a]);
  const dmMsg = await msg(dm, a, 'dm message');
  const react = (who, mid, emoji) => err(`insert into public.reactions (message_id, user_id, emoji) values ($1, $2, $3)`, [mid, who, emoji]);
  await act(b);
  h.eq('react: a normal member can', await react(b, m2, '👍'), null);
  await h.admin();
  await h.q(`update public.profiles set muted_until = now() + interval '1 hour' where id = $1`, [b]);
  await act(b);
  e = await react(b, m2, '😀');
  h.eq('react: a site timeout blocks it', /timed out/.test(e?.message ?? ''), true);
  e = await react(b, dmMsg, '😀');
  h.eq('react: a site timeout blocks it in DMs too', /timed out/.test(e?.message ?? ''), true);
  await knob('test.staff', '1');
  h.eq('react: staff skip it', await react(b, m2, '🎉'), null);
  await knob('test.staff', '');
  await knob('yapper.bot', '1');
  h.eq('react: a path that sets the bot flag skips it', await react(b, m2, '🤖'), null);
  await knob('yapper.bot', '');
  await act(null);
  h.eq('react: the service path (no signed-in user) skips it', await react(b, m2, '🛠️'), null);
  await h.admin();
  await h.q(`update public.profiles set muted_until = now() - interval '1 minute' where id = $1`, [b]);
  await act(b);
  h.eq('react: an expired site timeout does not block', await react(b, m2, '🙂'), null);
  // server timeout
  await h.admin();
  await h.q(`insert into public.server_timeouts (server_id, user_id, until) values ($1, $2, now() + interval '1 hour')`, [S2, c]);
  await act(c);
  e = await react(c, m2, '👍');
  h.eq('react: a server timeout blocks reacting in that server', /timed out in this server/.test(e?.message ?? ''), true);
  h.eq('react: ...but not in a DM', await react(c, dmMsg, '👍').then((x) => (x && /timed out/.test(x.message) ? x : null)), null);
  await h.admin();
  await h.q(`delete from public.server_timeouts`);
  await h.q(`insert into public.server_timeouts (server_id, user_id, until) values ($1, $2, now() + interval '1 hour')`, [S1, c]);
  await act(c);
  h.eq('react: a timeout in another server does not block here', await react(c, m2, '😎'), null);
  await h.admin();
  await h.q(`update public.server_timeouts set until = now() - interval '1 minute'`);
  await h.q(`update public.server_timeouts set server_id = $1`, [S2]);
  await act(c);
  h.eq('react: an expired server timeout does not block', await react(c, m2, '😮'), null);
  // standing
  await h.admin();
  await h.q(`insert into public.test_tier (user_id, tier) values ($1, 'very_limited')`, [d]);
  await act(d);
  e = await react(d, m2, '👍');
  h.eq('react: a very limited account can not react', /very limited/.test(e?.message ?? ''), true);
  await h.admin();
  await h.q(`update public.test_tier set tier = 'limited'`);
  await act(d);
  h.eq('react: a plain limited account still can', await react(d, m2, '👍'), null);
  await h.admin();
  await h.q(`update public.test_tier set tier = 'suspended'`);
  await act(d);
  e = await react(d, m2, '🔥');
  h.eq('react: a suspended account can not', /suspended/.test(e?.message ?? ''), true);
  await h.admin();

  // ----- 4. username hold message -----
  await act(b);
  await h.q(`update public.profiles set username = 'member_new' where id = $1`, [b]);
  await act(c);
  e = await err(`update public.profiles set username = 'member' where id = $1`, [c]);
  h.eq('hold: a name let go this week says it is held, and until when', /held until \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/.test(e?.message ?? ''), true);
  h.eq('hold: it is still a check violation (same error code as before)', e?.code, '23514');
  h.eq('hold: the time in the message is the hold end', (await h.one(`select to_char(until at time zone 'UTC', 'YYYY-MM-DD HH24:MI') as t from public.username_holds where name_key = 'member'`)).t, /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}) UTC/.exec(e?.message ?? '')?.[1]);
  await act(b);
  await h.ok('hold: the person who let it go can take it back', () => h.q(`update public.profiles set username = 'member' where id = $1`, [b]));

  // ----- grants -----
  await h.admin();
  h.eq('promo_invite_marks is closed to the app roles', (await h.one(`select has_table_privilege('authenticated', 'public.promo_invite_marks', 'select') or has_table_privilege('anon', 'public.promo_invite_marks', 'select') as open`)).open, false);
  h.eq('promo_invite_marks has RLS on', (await h.one(`select relrowsecurity from pg_class where oid = 'public.promo_invite_marks'::regclass`)).relrowsecurity, true);
  h.eq('trigger functions are not callable by the app roles', (await h.one(`select has_function_privilege('authenticated', 'public.reaction_guard()', 'execute') or has_function_privilege('authenticated', 'public.invites_only_in_promo()', 'execute') or has_function_privilege('anon', 'public.reaction_guard()', 'execute') as open`)).open, false);
}
