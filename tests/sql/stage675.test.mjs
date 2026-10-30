// 675: search_messages_v4 = v3 (409) plus mention (mentions:user) and pinned, and has:embed / sound / poll.
// Same stand-ins as stage409 (base 24 + flags, 298, 409), then 675 twice. Rows are seeded with triggers off
// (session_replication_role = replica) so created_at can be set and the new-account slowmode doesn't apply,
// and a 30k-row filler lets the planner show which index each filter uses.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage298.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(`alter table public.servers add column if not exists shut_down_at timestamptz;
    alter table public.messages add column if not exists embeds jsonb;
    create table if not exists public.polls (id uuid primary key default gen_random_uuid(), message_id uuid not null unique references public.messages (id) on delete cascade,
      channel_id uuid not null references public.channels (id) on delete cascade, question text not null default 'q', created_at timestamptz not null default now());`);
  await h.db.exec("create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable as $f$ select * from public.channels where false $f$;");
  await h.db.exec(mig('298_banned_cant_read.sql'));
  await h.db.exec("create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable security definer set search_path = public as $f$ select * from public.visible_server_channels(null) $f$;");
  await h.db.exec(mig('409_search_filters.sql'));
  const MIG = mig('675_search_filters_v4.sql');
  await h.ok('675 applies', () => h.db.exec(MIG));
  await h.ok('675 re-runs cleanly', () => h.db.exec(MIG));
  // The hand-built indexes (header of 409 and 675), without concurrently: PGlite runs everything in one session.
  await h.db.exec(`
    create index if not exists messages_attach_idx on public.messages (channel_id, created_at desc) where attachment_path is not null;
    create index if not exists messages_link_idx on public.messages (channel_id, created_at desc) where strpos(content, 'http') > 0;
    create index if not exists messages_mention_keys_idx on public.messages using gin (public.mention_keys(channel_id, content)) with (fastupdate = off) where strpos(content, '<@') > 0;
    create index if not exists messages_embeds_idx on public.messages (channel_id, created_at desc) where embeds is not null;`);

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  const c = await h.signup('c@test.dev', 'carl');
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'search'`);
  h.eq('flag search_filters is test for Antic and HQ test', await h.one(`select mode, servers::text s, users::text u from feature_flags where key = 'search_filters'`),
    { mode: 'test', s: '{00000000-0000-4000-8000-00000000b001}', u: '{00000000-0000-4000-8000-00000000a001}' });
  h.eq('mention_keys reads people, not roles, by person and channel:person', await h.one(`select array(select unnest(public.mention_keys($2, $1)) order by 1)::text x`, [`hi <@${a}> and <@&${b}> and <@${a}> <@${c}>`, b]),
    { x: `{${[a, c, `${b}:${a}`, `${b}:${c}`].sort().join(',')}}` });

  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [a])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, a, b]);
  const gen = (await h.one(`insert into channels (server_id, name, kind, created_by) values ($1, 'general', 'text', $2) returning id`, [sid, a])).id;
  const memes = (await h.one(`insert into channels (server_id, name, kind, created_by) values ($1, 'memes', 'text', $2) returning id`, [sid, a])).id;
  // Carl's own server, where Alice isn't a member: mentions of her there stay hidden from her.
  const s2 = (await h.one(`insert into servers (name, owner_id) values ('S2', $1) returning id`, [c])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [s2, c]);
  const hidden = (await h.one(`insert into channels (server_id, name, kind, created_by) values ($1, 'secret', 'text', $2) returning id`, [s2, c])).id;

  await h.db.exec(`set session_replication_role = replica`);
  let day = 0;
  const ins = async (ch, who, content, extra = {}) => {
    day++;
    const r = await h.one(`insert into messages (channel_id, author_id, content, attachment_path, embeds, pinned_at, created_at)
      values ($1, $2, $3, $4, $5::jsonb, $6, timestamptz '2026-10-01' + make_interval(days => $7)) returning id`,
      [ch, who, content, extra.path ?? null, extra.embeds ? JSON.stringify(extra.embeds) : null, extra.pinned ? new Date().toISOString() : null, day]);
    return r.id;
  };
  await ins(gen, b, `hey <@${a}> look`); // Oct 2
  await ins(gen, b, `<@${a}> hello again`, { pinned: true }); // Oct 3
  await ins(memes, a, `thanks <@${b}>`); // Oct 4
  await ins(gen, b, 'hello pinned plain', { pinned: true }); // Oct 5
  await ins(gen, a, 'bot card', { embeds: [{ title: 'x' }] }); // Oct 6
  await ins(gen, b, 'hello tune', { path: `${b}/r2-1.mp3` }); // Oct 7
  await ins(gen, b, 'voice note', { path: `${b}/r2-2.weba` }); // Oct 8
  const pollMsg = await ins(memes, a, '📊 lunch?'); // Oct 9
  await h.q(`insert into polls (message_id, channel_id) values ($1, $2)`, [pollMsg, memes]);
  await ins(hidden, c, `secret <@${a}> hello`); // Oct 10
  await ins(gen, b, `role ping <@&${a}> only`); // Oct 11
  await ins(gen, a, 'empty cards', { embeds: [] }); // Oct 12
  // Filler: 30k plain messages in general, a few hundred pinging other people, so the plans below are real ones.
  await h.q(`insert into messages (channel_id, author_id, content, created_at)
    select $1, $2, case when g % 100 = 0 then 'yo <@' || $3 || '> filler ' || g else 'filler message ' || g end, timestamptz '2025-01-01' + make_interval(mins => g)
    from generate_series(1, 30000) g`, [gen, b, c]);
  // And 2000 polls in Carl's server (not Alice's), so polls is big enough to need its index.
  await h.q(`with m as (insert into messages (channel_id, author_id, content, created_at)
      select $1, $2, '📊 filler poll ' || g, timestamptz '2025-06-01' + make_interval(mins => g) from generate_series(1, 2000) g returning id, created_at)
    insert into polls (message_id, channel_id, created_at) select id, $1, created_at from m`, [hidden, c]);
  await h.db.exec(`set session_replication_role = origin; analyze public.messages; analyze public.polls;`);

  // The index calls mention_keys on every write: a role that isn't authenticated must still be able to post.
  await h.db.exec(`do $r$ begin if not exists (select 1 from pg_roles where rolname = 'writer_test') then create role writer_test bypassrls; end if; end $r$;
    grant insert on public.messages to writer_test; set role writer_test;`);
  await h.ok('another role can still insert a mention (index expression is executable)', () =>
    h.q(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, $3, '2024-01-01')`, [memes, b, `old <@${c}>`]));
  await h.admin();
  await h.as(a);
  const n = async (sql, params = []) => (await h.one(`select count(*)::int n from ${sql}`, params)).n;
  const v4 = (args) => `search_messages_v4(${args})`;
  h.eq('mentions: me, in the server', await n(v4(`null, $1, null, null, null, null, null, $2`), [sid, a]), 2);
  h.eq('mentions: everywhere skips servers I am not in', await n(v4(`null, null, null, null, null, null, null, $1`), [a]), 2);
  h.eq('a role ping is not a mention of a person', await n(v4(`'role', $1, null, null, null, null, null, $2`), [sid, a]), 0);
  h.eq('mentions: plus words', await n(v4(`'hello', $1, null, null, null, null, null, $2`), [sid, a]), 1);
  h.eq('mentions: alice, from: bob', await n(v4(`null, $1, null, $2, null, null, null, $3`), [sid, b, a]), 2);
  h.eq('mentions: bob from alice', await n(v4(`null, $1, null, $2, null, null, null, $3`), [sid, a, b]), 1);
  h.eq('mentions: bob, in:#memes', await n(v4(`null, null, $1, null, null, null, null, $2`), [memes, b]), 1);
  h.eq('mentions: with before/after (during Oct 3)', await n(v4(`null, $1, null, null, '2026-10-04', '2026-10-02T23:59:59', null, $2`), [sid, a]), 1);
  h.eq('pinned:true', await n(v4(`null, $1, null, null, null, null, null, null, true`), [sid]), 2);
  h.eq('pinned:true plus words', await n(v4(`'plain', $1, null, null, null, null, null, null, true`), [sid]), 1);
  h.eq('pinned:true plus mentions:', await n(v4(`null, $1, null, null, null, null, null, $2, true`), [sid, a]), 1);
  h.eq('has:embed (an empty list is not one)', await n(v4(`null, $1, null, null, null, null, 'embed'`), [sid]), 1);
  h.eq('has:sound (voice messages too)', await n(v4(`null, $1, null, null, null, null, 'sound'`), [sid]), 2);
  h.eq('has:sound plus words', await n(v4(`'tune', $1, null, null, null, null, 'sound'`), [sid]), 1);
  h.eq('has:poll', await n(v4(`null, $1, null, null, null, null, 'poll'`), [sid]), 1);
  h.eq('has:poll plus words', await n(v4(`'lunch', $1, null, null, null, null, 'poll'`), [sid]), 1);
  h.eq('v3 filters still work: has:file', await n(v4(`'hello', $1, null, null, null, null, 'file'`), [sid]), 1);
  h.eq('unknown kind finds nothing', await n(v4(`'hello', $1, null, null, null, null, 'song'`), [sid]), 0);
  h.eq('pinned alone needs a place to look', await n(v4(`null, null, null, null, null, null, null, null, true`)), 0);
  h.eq('nothing asked, nothing found', await n(v4(`null, $1`), [sid]), 0);
  await h.as(c);
  h.eq('an outsider finds none of S by mention', await n(v4(`null, $1, null, null, null, null, null, $2`), [sid, a]), 0);
  h.eq('an outsider sees their own server', await n(v4(`null, null, null, null, null, null, null, $1`), [a]), 1);
  h.eq('mentions of carl: the filler is in S, not his', await n(v4(`null, null, null, null, null, null, null, $1`), [c]), 0);
  await h.as(b);
  h.eq('paging: mentions of carl, 50 at a time', await n(v4(`null, $1, null, null, null, null, null, $2`), [sid, c]), 50);
  await h.as(null);
  await h.fails('anon cannot call v4', `select * from search_messages_v4('hello')`);

  // Plans: the same query text v4 builds, with literals. None may read the whole messages table.
  await h.admin();
  const plan = async (sql) => (await h.q(`explain ${sql}`)).map((r) => r['QUERY PLAN']).join('\n');
  const noSeq = (name, p, idx) => {
    if (/Seq Scan on messages/.test(p)) throw new Error(`✗ ${name}: scans messages\n${p}`);
    if (idx && !p.includes(idx)) throw new Error(`✗ ${name}: expected ${idx}\n${p}`);
    if (process.env.SHOW_PLANS) console.log(`-- ${name}\n${p}`);
    h.passed++;
  };
  const chans = `array['${gen}','${memes}']::uuid[]`;
  const base = `m1.created_at < 'infinity' and m1.created_at > '-infinity'`;
  noSeq('mentions: everywhere uses messages_mention_keys_idx', await plan(`select m1.id, m1.channel_id, m1.created_at from public.messages m1 where ${base}
    and strpos(m1.content, '<@') > 0 and public.mention_keys(m1.channel_id, m1.content) @> array['${a}'::text] order by m1.created_at desc limit 5000`), 'messages_mention_keys_idx');
  const lateral = (where, from = 'public.messages m1', on = 'm1.channel_id = ch.id') => `select t.id from unnest(${chans}) as ch(id) cross join lateral (
    select m1.id, m1.created_at from ${from} where ${on} and ${base} and ${where} order by m1.created_at desc limit 50) t order by t.created_at desc limit 50`;
  const mentionPlan = await plan(lateral(`strpos(m1.content, '<@') > 0 and public.mention_keys(m1.channel_id, m1.content) @> array[ch.id::text || ':' || '${c}'::text]`));
  noSeq('mentions: in a server, one channel:person probe per channel', mentionPlan, 'messages_mention_keys_idx');
  if (!/Index Cond: \(mention_keys\(channel_id, content\) @> ARRAY\[\(\(\(ch\.id\)::text \|\| ':'::text\)/.test(mentionPlan)) throw new Error(`✗ probe keyed by channel\n${mentionPlan}`);
  h.passed++;
  const authorPlan = await plan(`select t.channel_id from unnest(${chans}) as ch(id) cross join lateral (select m1.channel_id, m1.created_at from public.messages m1
    where m1.channel_id = ch.id and m1.author_id = '${a}' and ${base} order by m1.created_at desc limit 50) t`);
  noSeq('from: alone stays index-only (v3)', authorPlan, 'Index Only Scan using messages_channel_author_idx');
  noSeq('pinned:true uses messages_pinned_idx', await plan(lateral('m1.pinned_at is not null')), 'messages_pinned_idx');
  noSeq('has:embed uses messages_embeds_idx', await plan(lateral(`m1.embeds is not null and public.search_has_v2(m1.content, m1.attachment_path, m1.embeds, 'embed')`)), 'messages_embeds_idx');
  noSeq('has:sound uses messages_attach_idx', await plan(lateral(`m1.attachment_path is not null and public.search_has_v2(m1.content, m1.attachment_path, m1.embeds, 'sound')`)), 'messages_attach_idx');
  noSeq('has:poll walks polls_channel_created_idx', await plan(`select t.id from unnest(${chans}) as ch(id) cross join lateral (
    select m1.id, p.created_at from public.polls p join public.messages m1 on m1.id = p.message_id
    where p.channel_id = ch.id and p.created_at < 'infinity' and p.created_at > '-infinity' and m1.channel_id = ch.id and ${base}
    order by p.created_at desc limit 50) t order by t.created_at desc limit 50`), 'polls_channel_created_idx');
}
