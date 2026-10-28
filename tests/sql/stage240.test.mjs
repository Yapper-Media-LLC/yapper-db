// 240: search by person. PGlite can't replay every migration, so: 001..024, flags (031, 041), a stand-in
// channel_history_ok (false for channels named "nohistory", true otherwise; the live one checks read_history),
// small stand-ins for the channel-permission pieces (no overrides here) and visible_server_channels copied verbatim
// from the live database (read-only, Oct 18; same as 199), then 240 twice (re-runnable). feature_on and
// feature_on_for_me are the real ones from 031/041 (they match live).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.channels add column if not exists category_id uuid;
alter table public.channels add column if not exists ticket_by uuid;
alter table public.roles add column if not exists auto text;
alter table public.roles add column if not exists auto_before timestamptz;
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin();
$$;
create or replace function public.channel_view_base(cid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql stable as $$ select base $$;
create or replace function public.channel_history_ok(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select c.name <> 'nohistory' from public.channels c where c.id = cid), true);
$$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 18. */
const LIVE = `
CREATE OR REPLACE FUNCTION public.visible_server_channels(sids uuid[])
 RETURNS SETOF channels
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with mine as (
    select sm.server_id, sm.joined_at, public.server_perm(sm.server_id, 'manage_server') as mg,
           exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and sm.server_id = any(f.servers)))) as cp
    from public.server_members sm
    where sm.user_id = auth.uid() and (sids is null or sm.server_id = any(sids))
  ),
  st as (select public.is_staff() as s)
  select c.*
  from public.channels c
  join mine on mine.server_id = c.server_id
  where case when mine.cp and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) then
      exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
      or public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
    else (
      not c.private
     or mine.mg
     or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
     or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid() where cr.channel_id = c.id)
     or exists (select 1 from public.channel_roles cr join public.roles r on r.id = cr.role_id
                where cr.channel_id = c.id
                  and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and mine.joined_at < r.auto_before)))
     or ((select s from st) and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
    ) end;
$function$;
revoke all on function public.visible_server_channels(uuid[]) from public, anon;
grant execute on function public.visible_server_channels(uuid[]) to authenticated, service_role;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '240_search_from.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(MIG);
  await h.ok('240 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat'); // not in the server

  await h.admin();
  h.eq('flag exists in test mode', (await h.one(`select mode from feature_flags where key = 'search_from'`)).mode, 'test');
  h.eq('flag kept on re-run (one row)', (await h.one(`select count(*)::int n from feature_flags where key = 'search_from'`)).n, 1);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [cat])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($4, $5) on conflict do nothing`, [sid, amy, bob, other, cat]);
  await h.q(`update feature_flags set mode = 'test', servers = array[$1::uuid] where key = 'search'`, [sid]);
  const ch = async (name, server, priv = false) =>
    (await h.one(`insert into channels (name, kind, server_id, created_by, private) values ($1, 'text', $2, $3, $4) returning id`, [name, server, amy, priv])).id;
  const gen = await ch('general', sid);
  const memes = await ch('memes', sid);
  const secret = await ch('secret', sid, true); // private: only amy (owner, manage_server)
  const nohist = await ch('nohistory', sid);
  const elsewhere = await ch('elsewhere', other);
  const grp = (await h.one(`insert into channels (name, kind, created_by) values ('grp', 'group', $1) returning id`, [amy])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [grp, amy, cat]);
  // A server channel bob is linked to only through channel_members (like a ticket), in a server he isn't in.
  const ticket = await ch('ticket', other, true);
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2)`, [ticket, bob]);

  // Seeded as admin with the new-account slowdown trigger off. 120 by amy in general (every 3rd says "hello"),
  // 30 by bob in general, 10 by amy in memes, 1 by amy in each of secret / nohistory / elsewhere / the group.
  await h.q(`alter table messages disable trigger user`);
  await h.q(
    `insert into messages (channel_id, author_id, content, created_at)
     select $1, $2, case when i % 3 = 0 then 'hello a' || i else 'a' || i end, timestamptz '2026-01-01' + i * interval '1 minute'
     from generate_series(0, 119) i`, [gen, amy]);
  await h.q(
    `insert into messages (channel_id, author_id, content, created_at)
     select $1, $2, 'hello b' || i, timestamptz '2026-01-01' + i * interval '1 minute' + interval '30 seconds'
     from generate_series(0, 29) i`, [gen, bob]);
  await h.q(
    `insert into messages (channel_id, author_id, content, created_at)
     select $1, $2, 'meme' || i, timestamptz '2026-01-02' + i * interval '1 minute'
     from generate_series(0, 9) i`, [memes, amy]);
  for (const c of [secret, nohist, elsewhere, grp, ticket]) {
    await h.q(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, 'hello hidden', '2026-02-01')`, [c, c === elsewhere || c === ticket ? cat : amy]);
  }
  await h.q(`alter table messages enable trigger user`);

  const search = async (q, opts = {}) =>
    h.q(`select id, channel_id, author_id, content, created_at from search_messages_v2($1, $2, $3, $4, $5)`,
      [q, opts.sid ?? null, opts.cid ?? null, opts.author ?? null, opts.before ?? null]);

  await h.as(bob);
  let r = await search('', { sid, author: amy });
  h.eq('author only: 50 newest, all amy', [r.length, r.every((m) => m.author_id === amy)], [50, true]);
  h.eq('author only: newest first, memes come first', [r[0].content, r[9].content, r[10].content], ['meme9', 'meme0', 'a119']);
  h.eq('author only: sorted newest first', r.every((m, i) => i === 0 || new Date(r[i - 1].created_at) >= new Date(m.created_at)), true);
  h.eq('author only: nothing from secret / nohistory / other servers', r.some((m) => m.content === 'hello hidden'), false);

  const p2 = await search(null, { sid, author: amy, before: r.at(-1).created_at });
  h.eq('paging: next 50 continue right after', [p2.length, p2[0].content, p2.at(-1).content], [50, 'a79', 'hello a30']);
  const p3 = await search(null, { sid, author: amy, before: p2.at(-1).created_at });
  h.eq('paging: last page has the rest', [p3.length, p3[0].content, p3.at(-1).content], [30, 'a29', 'hello a0']);
  const ids = new Set([...r, ...p2, ...p3].map((m) => m.id));
  h.eq('paging: no repeats, all 130 of amy\'s visible messages', ids.size, 130);

  r = await search('hello', { sid, author: amy });
  h.eq('q + author: only amy\'s hellos', [r.length, r.every((m) => m.author_id === amy && m.content.startsWith('hello a'))], [40, true]);
  r = await search('hello', { sid, author: bob });
  h.eq('q + author: only bob\'s hellos', [r.length, r.every((m) => m.author_id === bob)], [30, true]);
  r = await search('hello', { sid });
  h.eq('q alone: 50 newest hellos from both', [r.length, new Set(r.map((m) => m.author_id)).size], [50, 2]);
  h.eq('q alone: no hidden ones', r.some((m) => m.content === 'hello hidden'), false);
  r = await search('hello', { sid, before: r.at(-1).created_at });
  h.eq('q alone: paging gives the other 20', r.length, 20);

  r = await search('', { sid, author: amy, cid: memes });
  h.eq('author + one channel', [r.length, r.every((m) => m.channel_id === memes)], [10, true]);
  r = await search('', { sid, author: amy, cid: secret });
  h.eq('author in a channel I can\'t see: nothing', r.length, 0);
  r = await search('', { author: amy });
  h.eq('author with no server and no channel: nothing', r.length, 0);
  r = await search('hello', { author: amy });
  h.eq('q + author with no server and no channel: nothing', r.length, 0);
  r = await search('hidden', {});
  h.eq('server channel I\'m only linked to via channel_members (no server picked): hidden', r.length, 0);
  r = await search('hidden', { cid: ticket });
  h.eq('same channel picked directly: hidden', r.length, 0);
  r = await search('', { cid: ticket, author: cat });
  h.eq('same channel, author filter: hidden', r.length, 0);
  h.eq('negation only (-hello): nothing', (await search('-hello', { sid })).length, 0);
  h.eq('negation only with an author: nothing', (await search('-hello', { sid, author: amy })).length, 0);
  h.eq('no words at all (!!): nothing', (await search('!!', { sid })).length, 0);
  h.eq('hello -b0: negation next to a word still works (drops bob\'s "hello b0")', (await search('hello -b0', { sid, author: bob })).length, 29);
  await h.ok('10k-character q is cut, no error', () => search('hello '.repeat(1700), { sid }));
  r = await search('hello ' + 'x'.repeat(10000), { sid });
  h.eq('10k-character q: cut to 200 (hello + 194 x\'s, no match)', r.length, 0);
  r = await search('', { cid: grp, author: amy });
  h.eq('group I\'m not in: nothing', r.length, 0);

  h.eq('empty q, no author: nothing', (await search('', { sid })).length, 0);
  h.eq('blank q, no author: nothing', (await search('   ', { sid })).length, 0);
  h.eq('null q, no author: nothing', (await search(null, { sid })).length, 0);

  await h.as(amy);
  r = await search('hidden', {});
  h.eq('amy sees secret + her group, not nohistory or the other server',
    r.map((m) => m.channel_id).sort(), [secret, grp].sort());
  r = await search('', { cid: grp, author: amy });
  h.eq('author in a group: works', r.length, 1);

  await h.as(cat);
  r = await search('', { sid, author: amy });
  h.eq('non-member: nothing from the server', r.length, 0);
  r = await search('hello', { cid: grp, author: amy });
  h.eq('search not on for cat (no test server): not even the group', r.length, 0);
  await h.admin();
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'search'`, [cat]);
  await h.as(cat);
  r = await search('hello', { cid: grp, author: amy });
  h.eq('search on for cat: the group they share works', [r.length, r[0]?.channel_id], [1, grp]);
  r = await search('hello', {});
  h.eq('search on for cat: no server picked, the group and their own server, nothing from S',
    r.map((m) => m.channel_id).sort(), [elsewhere, grp, ticket].sort());

  // A busy server elsewhere with 5,000 newer "hello"s: with S picked, they don't use up the cap.
  await h.admin();
  await h.q(`alter table messages disable trigger user`);
  await h.q(`insert into messages (channel_id, author_id, content, created_at)
     select $1, $2, 'hello busy', timestamptz '2026-03-01' + i * interval '1 second' from generate_series(1, 5000) i`, [elsewhere, cat]);
  await h.q(`alter table messages enable trigger user`);
  await h.as(bob);
  h.eq('server picked: busy server elsewhere doesn\'t crowd it out', (await search('hello', { sid })).length, 50);

  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'search'`);
  await h.as(bob);
  h.eq('search flag off: nothing in the server', (await search('', { sid, author: amy })).length, 0);
  await h.as(amy);
  h.eq('search flag off: nothing in DMs / groups either', (await search('hidden', { cid: grp })).length, 0);

  await h.as(null);
  await h.fails('anon cannot call it', `select * from search_messages_v2('hello', null, null, null, null)`);
}
