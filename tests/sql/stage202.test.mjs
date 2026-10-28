// 202: bug batch. Slowmode on edits, invite edits in #promote-your-server, HQ promo slowmode, text-only channels
// counting only media links, author_bot on bot message events, no friend requests to bots, bots not auto-joining
// HQ, replies counting as mentions in unread_counts_v2.
// PGlite can't replay every migration, so like stage192/193 this starts from stage 24 (+ flags 031/041), adds small
// stand-ins for the live pieces 202 leans on, then the live definitions of bot_webhooks, send_friend_request and
// is_bot_user copied verbatim from the live database (read-only, Oct 17), so the in-place patches are checked against
// the real text. Then 202 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
create or replace function public.server_timed_out(sid uuid, uid uuid) returns timestamptz language sql stable security definer set search_path = public as $$ select null::timestamptz $$;

alter table public.channels add column if not exists auto_slow_until timestamptz;
alter table public.channels add column if not exists no_images boolean not null default false;
alter table public.channels add column if not exists category_id uuid;
alter table public.messages add column if not exists webhook jsonb;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.profiles add column if not exists dms_from text;
alter table public.friendships add column if not exists note text;
-- Live has only the (text, text) version.
drop function if exists public.send_friend_request(text);
create table if not exists public.friend_request_declines (requester uuid, addressee uuid, declined_at timestamptz default now());
create table if not exists public.post_marks (channel_id uuid, author_id uuid, kind text, at timestamptz not null default now(),
  album_n int not null default 0, primary key (channel_id, author_id, kind));
create table if not exists public.bots (id uuid primary key, owner_id uuid, name text, webhook_url text, webhook_secret text);
create table if not exists public.bot_accounts (bot text primary key, user_id uuid);
create table if not exists public.bot_servers (bot_id uuid, server_id uuid);
create table if not exists public.bot_commands (bot_id uuid, name text);
create table if not exists public.bot_events (id bigserial primary key, bot_id uuid, type text, data jsonb);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin();
$$;
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select public.server_perm(c.server_id, perm) from public.channels c where c.id = cid and c.server_id is not null), true);
$$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql stable as $$ select true $$;
create or replace function public.channel_overrides_live(cid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.bot_channel_visible(bid uuid, cid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.bot_push(bid uuid, hook_url text, hook_secret text, ev text, payload jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.bot_events (bot_id, type, data) values (bid, ev, payload);
$$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$ select true $$;
create or replace function public.has_slur(t text) returns boolean language sql stable as $$ select false $$;
create or replace function public.has_adult_link(t text) returns boolean language sql stable as $$ select false $$;
create or replace function public.my_role_pings() returns table(sid uuid, pats text[]) language sql stable as $$ select null::uuid, null::text[] where false $$;
create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable security definer set search_path = public as $$
  select c.* from public.channels c join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid();
$$;
-- 202 replaces these two; the live triggers need a function to point at first.
create or replace function public.invites_only_in_promo() returns trigger language plpgsql as $$ begin return new; end $$;
create or replace function public.no_images_channel() returns trigger language plpgsql as $$ begin return new; end $$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
const LIVE = String.raw`
CREATE OR REPLACE FUNCTION public.is_bot_user(uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.bots b where b.id = uid) or exists (select 1 from public.bot_accounts a where a.user_id = uid);
$function$;
CREATE OR REPLACE FUNCTION public.bot_webhooks()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare live boolean; sid uuid; b record; chname text; priv boolean; payload jsonb; cmd text; args text; m text[];
begin
  select server_id, name, private into sid, chname, priv from public.channels where id = new.channel_id;
  if sid is null then return null; end if;
  if not exists (select 1 from public.bot_servers bs where bs.server_id = sid) then return null; end if;
  m := regexp_match(coalesce(new.content, ''), '^[/!]([a-z0-9_-]{1,32})(?:\s+([\s\S]*))?$', 'i');
  if m is not null then cmd := lower(m[1]); args := coalesce(btrim(m[2]), ''); end if;
  payload := jsonb_build_object(
    'id', new.id, 'channel_id', new.channel_id, 'channel_name', chname, 'server_id', sid, 'author_id', new.author_id,
    'author', (select username from public.profiles where id = new.author_id),
    'content', new.content, 'attachment', new.attachment_path, 'reply_to_id', new.reply_to_id, 'created_at', new.created_at);
  live := public.channel_overrides_live(new.channel_id);
  for b in select bo.id, bo.webhook_url, bo.webhook_secret from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id
           where bs.server_id = sid and bo.id <> new.author_id loop
    if (coalesce(priv, false) or live) and not public.bot_channel_visible(b.id, new.channel_id) then continue; end if;
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, 'message',
      payload || jsonb_build_object('mentioned', coalesce(new.content, '') like '%<@' || b.id::text || '>%')
              || case when cmd is not null and exists (select 1 from public.bot_commands c where c.bot_id = b.id and c.name = cmd)
                      then jsonb_build_object('command', cmd, 'args', args) else '{}'::jsonb end);
  end loop;
  return null;
end $function$;
CREATE OR REPLACE FUNCTION public.send_friend_request(target_username text, note text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := auth.uid();
  target uuid;
  existing public.friendships;
  pref text;
  clean text := nullif(btrim(regexp_replace(coalesce(send_friend_request.note, ''), '\s+', ' ', 'g')), '');
begin
  if me is null then raise exception 'Not signed in'; end if;
  if clean is not null and not public.feature_on_for_me('friend_notes') then clean := null; end if;
  if clean is not null then
    if char_length(clean) > 100 then raise exception 'Notes are up to 100 characters' using errcode = 'check_violation'; end if;
    if public.has_slur(clean) then
      raise exception 'That contains a slur, so it wasn''t sent. Keep it respectful.' using errcode = 'check_violation';
    end if;
    if public.has_adult_link(clean) then
      raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
    end if;
  end if;
  select id into target from public.profiles where lower(username) = lower(btrim(target_username));
  if target is null then raise exception 'Hm, that didn''t work. Double check the username.'; end if;
  if target = me then raise exception 'You can''t friend yourself (we checked)'; end if;
  if public.is_blocked_between(me, target) then
    raise exception 'Hm, that didn''t work. Double check the username.';
  end if;

  select * into existing from public.friendships
  where least(requester, addressee) = least(me, target)
    and greatest(requester, addressee) = greatest(me, target);

  if existing.id is not null then
    if existing.status = 'accepted' then raise exception 'You''re already friends'; end if;
    if existing.requester = me then raise exception 'Request already sent'; end if;
    update public.friendships set status = 'accepted', accepted_at = now() where id = existing.id;
    return 'accepted';
  end if;

  if (select count(*) from public.friendships where requester = me and status = 'pending') >= 100 then
    raise exception 'Too many pending requests';
  end if;
  if exists (select 1 from public.friend_request_declines d
             where d.requester = me and d.addressee = target and d.declined_at > now() - interval '24 hours') then
    raise exception 'You sent them a request not long ago. Try again tomorrow.';
  end if;
  -- The note only goes along when they'd take a DM from me (friends-only people get the request without it).
  if clean is not null then
    select coalesce(dms_from, 'friends') into pref from public.profiles where id = target;
    if not (pref = 'everyone' or (pref = 'servers' and exists (
      select 1 from public.server_members a join public.server_members b on a.server_id = b.server_id
      where a.user_id = me and b.user_id = target))) then
      clean := null;
    end if;
  end if;
  insert into public.friendships (requester, addressee, note) values (me, target, clean);
  return 'sent';
end;
$function$;
create trigger messages_bot_webhooks after insert on public.messages for each row execute function public.bot_webhooks();
create trigger messages_invites_only_in_promo before insert or update of content on public.messages for each row execute function public.invites_only_in_promo();
create trigger messages_no_images before insert or update of content, attachment_path on public.messages for each row execute function public.no_images_channel();
-- The insert slowmode and new-account limits aren't under test here.
alter table public.messages disable trigger messages_slowmode;
alter table public.messages disable trigger messages_raid_guard;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);

  const owner = await h.signup('owner@test.dev', 'owner');
  const u = await h.signup('u@test.dev', 'yuki');
  const v = await h.signup('v@test.dev', 'vera');
  const botUser = async (email, username) => {
    await h.admin();
    return (await h.one(`insert into auth.users (email, raw_user_meta_data) values ($1, $2::jsonb) returning id`,
      [email, JSON.stringify({ username, bot: true })])).id;
  };
  await h.as(owner);
  const S = (await h.one(`select create_server('Test', null) id`)).id;
  const H = (await h.one(`select create_server('HQ', null) id`)).id;
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id) values ($1, $3), ($1, $4), ($2, $3), ($2, $4) on conflict do nothing`, [S, H, u, v]);
  const chan = async (sid, name, slow = 0, noImages = false) =>
    (await h.one(`insert into channels (server_id, kind, name, slowmode, no_images) values ($1, 'text', $2, $3, $4) returning id`, [sid, name, slow, noImages])).id;
  const cSlow = await chan(S, 'slow', 60);
  const cText = await chan(S, 'text-only', 0, true);
  const cReplies = await chan(S, 'replies');
  const cPromo = await chan(H, 'promote-your-server', 3600);
  const cGeneral = await chan(H, 'general', 3600);
  await h.q(`update app_settings set default_server_id = $1`, [H]);
  // A bot made before 202 joined HQ; 202 leaves that membership alone.
  const oldBot = await botUser('oldbot@bots.yapper.website', 'oldbot');
  h.eq('before 202: a new bot account joined HQ', !!(await h.one(`select 1 x from server_members where server_id = $1 and user_id = $2`, [H, oldBot])), true);

  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '202_bug_batch.sql'), 'utf8');
  await h.db.exec(sql);
  await h.db.exec(sql); // re-runnable

  const tryAs = async (uid, q, params = [], bot = false) => {
    await h.as(uid);
    try {
      if (bot) await h.db.exec(`select set_config('yapper.bot', '1', false)`);
      return (await h.q(q, params), null);
    } catch (e) { return e.message; } finally {
      if (bot) await h.db.exec(`select set_config('yapper.bot', '', false)`);
      await h.admin();
    }
  };
  const post = async (uid, cid, text, extra = {}) => {
    await h.as(uid);
    try {
      return (await h.one(`insert into messages (channel_id, author_id, content, reply_to_id, attachment_path) values ($1, $2, $3, $4, $5) returning id`,
        [cid, uid, text, extra.reply ?? null, extra.attachment ?? null])).id;
    } catch (e) { return 'ERR ' + e.message; } finally { await h.admin(); }
  };
  const edit = (uid, id, text, bot = false) => tryAs(uid, `update messages set content = $2 where id = $1`, [id, text], bot);
  const backdate = async (id, what) => {
    await h.db.exec(`set session_replication_role = replica`); // skip the edit triggers for this backdate
    await h.q(`update messages set created_at = created_at - $2::interval where id = $1`, [id, what]);
    await h.db.exec(`set session_replication_role = origin`);
  };

  // ---- 1. slowmode on edits ----
  const m1 = await post(u, cSlow, 'first');
  h.eq('post in a slowmode channel', typeof m1 === 'string' && !m1.startsWith('ERR'), true);
  h.eq('first edit right after posting is free', await edit(u, m1, 'first!'), null);
  h.eq('next edit: no edit mark yet, allowed', await edit(u, m1, 'first!!'), null);
  const third = await edit(u, m1, 'first!!!');
  h.eq('third edit within the slowmode is refused', /^Slowmode is on\. You can edit again in \d+s$/.test(third ?? ''), true);
  h.eq('... content kept', (await h.one(`select content from messages where id = $1`, [m1])).content, 'first!!');
  h.eq('unchanged content (e.g. suppress embeds) is not throttled', await edit(u, m1, 'first!!'), null);
  await h.q(`update post_marks set at = at - interval '61 seconds' where author_id = $1 and kind = 'edit'`, [u]);
  h.eq('after the slowmode, editing works again', await edit(u, m1, 'first?'), null);
  const om = await post(owner, cSlow, 'mod');
  await edit(owner, om, 'mod 1'); await edit(owner, om, 'mod 2');
  h.eq('Manage Messages is not throttled', await edit(owner, om, 'mod 3'), null);
  h.eq('bots are not throttled', await edit(u, m1, 'bot edit', true), null);
  const m2 = await post(u, cSlow, 'old one');
  await backdate(m2, '10 minutes');
  h.eq('old message: no free first edit', (await edit(u, m2, 'old one!'))?.startsWith('Slowmode is on'), true);
  await h.q(`update channels set slowmode = 21600 where id = $1`, [cSlow]);
  await h.q(`update post_marks set at = now() - interval '901 seconds' where author_id = $1 and kind = 'edit'`, [u]);
  h.eq('long slowmode: edits wait at most 15 minutes', await edit(u, m2, 'old one?'), null);
  await h.q(`update channels set slowmode = 0 where id = $1`, [cSlow]);
  h.eq('no slowmode: edits are free', [await edit(u, m2, 'a'), await edit(u, m2, 'b'), await edit(u, m2, 'c')], [null, null, null]);
  await h.q(`update channels set auto_slow_until = now() + interval '1 minute' where id = $1`, [cSlow]);
  h.eq('auto slowmode counts too', (await edit(u, m2, 'd'))?.startsWith('Slowmode is on'), true);

  // ---- 2. + 3. invites in #promote-your-server ----
  h.eq('HQ promo slowmode is 6 h now', (await h.one(`select slowmode from channels where id = $1`, [cPromo])).slowmode, 21600);
  h.eq('other HQ channels keep theirs', (await h.one(`select slowmode from channels where id = $1`, [cGeneral])).slowmode, 3600);
  const p1 = await post(u, cPromo, 'join my server discord.gg/abc123');
  h.eq('invite post goes in', p1.startsWith('ERR'), false);
  h.eq('editing the text around the same invite works', await edit(u, p1, 'join my cool server discord.gg/abc123 !!'), null);
  h.eq('editing in a different invite is a new invite post', (await edit(u, p1, 'join discord.gg/zzz999'))?.startsWith('You can post an invite in #promote-your-server once every 6 hours'), true);
  h.eq('adding a second invite too', (await edit(u, p1, 'discord.gg/abc123 and discord.gg/other'))?.startsWith('You can post an invite'), true);
  h.eq('same invite again (other case) is fine', await edit(u, p1, 'come hang: Discord.gg/abc123'), null);
  h.eq('a second invite post within 6 h is refused', (await post(u, cPromo, 'discord.gg/again'))?.includes('once every 6 hours'), true);
  h.eq('invites elsewhere in HQ are still refused', (await post(v, cGeneral, 'discord.gg/abc'))?.includes('only go in #promote-your-server'), true);
  const g1 = await post(v, cGeneral, 'hello');
  h.eq('editing an invite into another HQ channel is refused', (await edit(v, g1, 'discord.gg/abc'))?.includes('only go in'), true);

  // ---- 4. text-only channels ----
  h.eq('a bare ".gif" in text is fine', (await post(u, cText, 'send a .gif please')).startsWith('ERR'), false);
  h.eq('"song.mp3" in text is fine', (await post(u, cText, 'that song.mp3 slaps')).startsWith('ERR'), false);
  h.eq('a link that only contains .gif is fine', (await post(u, cText, 'https://example.com/a.gifts/page')).startsWith('ERR'), false);
  h.eq('a gif link is refused', (await post(u, cText, 'look https://example.com/cat.gif'))?.includes('text only'), true);
  h.eq('a png link with a query is refused', (await post(u, cText, 'https://example.com/x.PNG?w=200 nice'))?.includes('text only'), true);
  h.eq('a link in brackets is refused', (await post(u, cText, '(https://example.com/x.mp4)'))?.includes('text only'), true);
  h.eq('gif sites are refused', (await post(u, cText, 'https://tenor.com/view/abc'))?.includes('text only'), true);
  h.eq('attachments are refused', (await post(u, cText, '', { attachment: 'u/pic.png' }))?.includes('text only'), true);
  const t1 = await post(u, cText, 'plain');
  h.eq('editing a gif link in is refused', (await edit(u, t1, 'https://example.com/cat.gif'))?.includes('text only'), true);
  h.eq('managers can post media', (await post(owner, cText, 'https://example.com/cat.gif')).startsWith('ERR'), false);

  // ---- 5. author_bot on message events ----
  const botA = await botUser('a@bots.yapper.website', 'bota');
  const botB = await botUser('b@bots.yapper.website', 'botb');
  await h.q(`insert into bots (id, owner_id, name) values ($1, $3, 'A'), ($2, $3, 'B')`, [botA, botB, owner]);
  await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $3), ($2, $3)`, [botA, botB, S]);
  await h.q(`delete from bot_events`);
  await post(u, cReplies, 'hi bots');
  await h.db.exec(`select set_config('yapper.bot', '1', false)`);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'beep from A')`, [cReplies, botA]);
  await h.db.exec(`select set_config('yapper.bot', '', false)`);
  await h.q(`insert into messages (channel_id, author_id, content, webhook) values ($1, $2, 'from a webhook', '{"name":"hook"}')`, [cReplies, owner]);
  const evs = await h.q(`select bot_id, data->>'content' content, data->'author_bot' ab from bot_events order by id`);
  h.eq('events with author_bot', evs.map((e) => [e.bot_id === botA ? 'A' : 'B', e.content, e.ab]), [
    ['A', 'hi bots', false], ['B', 'hi bots', false],
    ['B', 'beep from A', true],
    ['A', 'from a webhook', true], ['B', 'from a webhook', true],
  ]);
  await h.q(`delete from bot_events`);
  await h.q(`delete from messages where channel_id = $1`, [cReplies]);

  // ---- 6. friend requests to bots ----
  h.eq('a friend request to a bot is refused', await tryAs(u, `select send_friend_request('bota')`), 'Bots can\'t be friends');
  h.eq('... not stored', (await h.one(`select count(*)::int n from friendships where addressee = $1`, [botA])).n, 0);
  h.eq('people still work', await tryAs(u, `select send_friend_request('vera')`), null);
  h.eq('... stored', (await h.one(`select status from friendships where requester = $1 and addressee = $2`, [u, v])).status, 'pending');

  // ---- 7. bots don't join HQ ----
  const human = await h.signup('new@test.dev', 'newbie');
  h.eq('a new person joins HQ', !!(await h.one(`select 1 x from server_members where server_id = $1 and user_id = $2`, [H, human])), true);
  h.eq('a new bot account doesn\'t', !!(await h.one(`select 1 x from server_members where server_id = $1 and user_id = $2`, [H, botA])), false);
  h.eq('an older bot keeps its membership', !!(await h.one(`select 1 x from server_members where server_id = $1 and user_id = $2`, [H, oldBot])), true);

  // ---- 8. replies count as mentions ----
  const mine = await post(u, cReplies, 'my message');
  const theirs = await post(v, cReplies, 'their message');
  await h.q(`insert into channel_reads (user_id, channel_id, last_read_at) values ($1, $2, now()) on conflict (user_id, channel_id) do update set last_read_at = now()`, [u, cReplies]);
  await post(v, cReplies, 'reply to yuki', { reply: mine });
  await post(v, cReplies, 'reply to self', { reply: theirs });
  await post(v, cReplies, 'plain');
  await post(v, cReplies, `ping <@${u}>`, { reply: mine }); // both: still one mention
  await h.as(u);
  const row = await h.one(`select unread, mentions from unread_counts_v2() where channel_id = $1`, [cReplies]);
  await h.admin();
  h.eq('replies to me count as mentions, once each', row, { unread: 4, mentions: 2 });
  await h.as(v);
  const vrow = await h.one(`select unread, mentions from unread_counts_v2() where channel_id = $1`, [cReplies]);
  await h.admin();
  h.eq('others\' replies don\'t ping me', vrow, { unread: 1, mentions: 0 });

  // ---- hygiene: security definer functions keep search_path, anon can't run the new one ----
  const defs = await h.q(`select p.proname, p.prosecdef, p.proconfig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('message_edit_slowmode', 'invites_only_in_promo', 'no_images_channel', 'bot_webhooks',
      'send_friend_request', 'join_default_server', 'unread_counts_v2') order by 1`);
  h.eq('all security definer with search_path', defs.map((d) => [d.proname, d.prosecdef, d.proconfig]), [
    ['bot_webhooks', true, ['search_path=public']], ['invites_only_in_promo', true, ['search_path=public']],
    ['join_default_server', true, ['search_path=public']], ['message_edit_slowmode', true, ['search_path=public']],
    ['no_images_channel', true, ['search_path=public']], ['send_friend_request', true, ['search_path=public']],
    ['unread_counts_v2', true, ['search_path=public']],
  ]);
  h.eq('anon can\'t execute message_edit_slowmode', (await h.one(`select has_function_privilege('anon', 'public.message_edit_slowmode()', 'execute') x`)).x, false);
  h.eq('anon can\'t execute server_timed_out', (await h.one(`select has_function_privilege('anon', 'public.server_timed_out(uuid,uuid)', 'execute') x`)).x, false);
  h.eq('signed-in users can execute server_timed_out', (await h.one(`select has_function_privilege('authenticated', 'public.server_timed_out(uuid,uuid)', 'execute') x`)).x, true);
}
