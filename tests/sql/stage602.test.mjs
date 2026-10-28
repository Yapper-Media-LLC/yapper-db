// 602: lobby v2 (flag lobby_v2). set_server_lobby_v2 saves content, look and sections in one call: managers only,
// both flags on, the look cleaned to known keys and values, buttons to https links or this server's channels,
// sections to known blocks, and the content still goes through set_server_lobby's checks.
// Starts from stage 24 with the same stand-ins as 533.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const LOBBY = mig('533_server_lobby.sql');
const MIG = mig('602_lobby_v2.sql');
// jsonb comes back with its keys sorted: compare with sorted keys too.
const sorted = (v) => Array.isArray(v) ? v.map(sorted) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])])) : v;

const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists ticket_by uuid;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create or replace function public.has_slur(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badword%' $$;
create or replace function public.has_sexual_spam(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%spamword%' $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badsite.com%' $$;
create table if not exists public.audit_seen (sid uuid, act text, actor uuid, extra jsonb);
create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
 returns void language sql security definer set search_path = public as $$ insert into public.audit_seen values (sid, act, auth.uid(), extra) $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`602 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LOBBY);
  // A lobby saved before 602: it keeps working and gets the new columns' defaults.
  const owner = await h.signup('o@x.com', 'owner');
  const member = await h.signup('p@x.com', 'plain');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner])).id;
  for (const u of [owner, member]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  await h.q(`update feature_flags set servers = array_append(servers, $1) where key = 'server_lobby'`, [S]);
  await h.as(owner);
  await h.q(`select public.set_server_lobby($1, 'Old about', '[]'::jsonb, '{}'::uuid[], true)`, [S]);

  await h.admin();
  await h.ok('602 runs', () => h.db.exec(MIG));
  await h.ok('602 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag lobby_v2 in test', (await h.one(`select mode from feature_flags where key = 'lobby_v2'`))?.mode, 'test');
  const before = await h.one(`select about, style, sections from server_lobby where server_id = $1`, [S]);
  h.eq('old lobby kept, new columns empty', [before.about, before.style, before.sections], ['Old about', {}, []]);

  const chan = async (sid, name) => (await h.one(`insert into channels (server_id, name, kind) values ($1, $2, 'text') returning id`, [sid, name])).id;
  const general = await chan(S, 'general');
  const elsewhere = await chan(other, 'theirs');
  const ticket = await chan(S, 'ticket-1');
  await h.q(`update channels set ticket_by = $1 where id = $2`, [member, ticket]);

  const call = `select public.set_server_lobby_v2($1, $2, '[]'::jsonb, $3::uuid[], $4, $5::jsonb, $6::jsonb)`;
  const save = async (style, sections = [], about = 'Hi', featured = [], staff = true) =>
    (await h.as(owner), h.q(call, [S, about, featured, staff, JSON.stringify(style), JSON.stringify(sections)]));
  const row = async () => { await h.admin(); return h.one(`select about, featured, show_staff, style, sections from server_lobby where server_id = $1`, [S]); };

  // Flag gate: lobby_v2 off for the server.
  await h.as(owner);
  await h.fails('refused while lobby_v2 is off for the server', call, [S, 'x', [], true, '{}', '[]']);
  await h.admin();
  await h.q(`update feature_flags set servers = array_append(servers, $1) where key = 'lobby_v2'`, [S]);

  // A full save.
  await h.as(owner);
  await h.ok('owner saves a full look', () => save({
    preset: 'magazine', bg: 'mesh', cards: 'glass', font: 'display', hero: 'tall', align: 'center',
    accent: '#FF8800', tagline: '  The comfiest corner  ', junk: 'dropped',
    buttons: [{ label: ' YouTube ', url: 'https://youtube.com/@x', extra: 1 }, { label: 'Say hi', channel: general }, { label: '', url: '' }],
  }, [{ id: 'live', on: true }, { id: 'about', on: false }, { id: 'live', on: false }, { id: 'faq' }], '  New about  ', [general], false));
  let r = await row();
  h.eq('content saved through set_server_lobby (trimmed)', [r.about, r.featured, r.show_staff], ['New about', [general], false]);
  h.eq('style cleaned: known keys only, accent lowercased, tagline trimmed', sorted(r.style), sorted({
    preset: 'magazine', bg: 'mesh', cards: 'glass', font: 'display', hero: 'tall', align: 'center', accent: '#ff8800',
    tagline: 'The comfiest corner',
    buttons: [{ label: 'YouTube', url: 'https://youtube.com/@x' }, { label: 'Say hi', channel: general }],
  }));
  h.eq('sections: in order, repeats skipped, on defaults to true', sorted(r.sections), [{ id: 'live', on: true }, { id: 'about', on: false }, { id: 'faq', on: true }]);
  await h.ok('empty look clears it', () => save({}, []));
  r = await row();
  h.eq('cleared', [r.style, r.sections], [{}, []]);
  await h.ok('null accent is fine (auto)', () => save({ accent: null }));
  h.eq('null accent not stored', (await row()).style, {});

  // Who can write.
  await h.as(member);
  await h.fails('plain member refused', call, [S, 'x', [], true, '{}', '[]']);
  await h.as(null);
  await h.fails('logged out refused', call, [S, 'x', [], true, '{}', '[]']);

  // Refusals.
  await h.as(owner);
  await h.fails('unknown preset', call, [S, '', [], true, '{"preset":"neon"}', '[]']);
  await h.fails('non-text preset', call, [S, '', [], true, '{"bg":{"x":1}}', '[]']);
  await h.fails('bad accent', call, [S, '', [], true, '{"accent":"red"}', '[]']);
  await h.fails('accent with css in it', call, [S, '', [], true, '{"accent":"#fff;background:url(x)"}', '[]']);
  await h.fails('style not an object', call, [S, '', [], true, '[]', '[]']);
  await h.fails('tagline over 120', call, [S, '', [], true, JSON.stringify({ tagline: 'x'.repeat(121) }), '[]']);
  await h.fails('filtered tagline', call, [S, '', [], true, '{"tagline":"badword"}', '[]']);
  await h.fails('5 buttons', call, [S, '', [], true, JSON.stringify({ buttons: Array.from({ length: 5 }, () => ({ label: 'a', url: 'https://a.com' })) }), '[]']);
  await h.fails('button without label', call, [S, '', [], true, '{"buttons":[{"label":"","url":"https://a.com"}]}', '[]']);
  await h.fails('long button label', call, [S, '', [], true, JSON.stringify({ buttons: [{ label: 'x'.repeat(25), url: 'https://a.com' }] }), '[]']);
  await h.fails('filtered button label', call, [S, '', [], true, '{"buttons":[{"label":"spamword","url":"https://a.com"}]}', '[]']);
  await h.fails('http link', call, [S, '', [], true, '{"buttons":[{"label":"a","url":"http://a.com"}]}', '[]']);
  await h.fails('javascript link', call, [S, '', [], true, '{"buttons":[{"label":"a","url":"javascript:alert(1)"}]}', '[]']);
  await h.fails('fake host with a user part', call, [S, '', [], true, '{"buttons":[{"label":"a","url":"https://www.yapper.website@evil.com/x"}]}', '[]']);
  await h.ok('odd on value counts as on', () => save({}, [{ id: 'faq', on: 'yes' }]));
  await h.as(owner);
  await h.fails('link without a dot', call, [S, '', [], true, '{"buttons":[{"label":"a","url":"https://localhost"}]}', '[]']);
  await h.fails('blocked site link', call, [S, '', [], true, '{"buttons":[{"label":"a","url":"https://badsite.com/x"}]}', '[]']);
  await h.fails('channel from another server', call, [S, '', [], true, JSON.stringify({ buttons: [{ label: 'a', channel: elsewhere }] }), '[]']);
  await h.fails('ticket channel', call, [S, '', [], true, JSON.stringify({ buttons: [{ label: 'a', channel: ticket }] }), '[]']);
  await h.fails('channel not a uuid', call, [S, '', [], true, '{"buttons":[{"label":"a","channel":"nope"}]}', '[]']);
  await h.fails('unknown section', call, [S, '', [], true, '{}', '[{"id":"ads","on":true}]']);
  await h.fails('sections not a list', call, [S, '', [], true, '{}', '{"id":"faq"}']);
  await h.fails('21 sections', call, [S, '', [], true, '{}', JSON.stringify(Array.from({ length: 21 }, () => ({ id: 'faq', on: true })))]);
  await h.fails('content checks still apply (filtered about)', call, [S, 'badword', [], true, '{}', '[]']);
  await h.fails('content checks still apply (other server channel)', call, [S, '', [elsewhere], true, '{}', '[]']);

  // A refused save changes nothing.
  await h.as(owner);
  await h.ok('a good save', () => save({ preset: 'spotlight' }, [{ id: 'faq', on: true }], 'Kept'));
  await h.as(owner);
  await h.fails('bad look after good content', call, [S, 'Changed', [], true, '{"preset":"neon"}', '[]']);
  r = await row();
  h.eq('still the good save', [r.about, r.style], ['Kept', { preset: 'spotlight' }]);

  // Direct writes are still closed.
  await h.as(owner);
  await h.fails('owner cannot update the look directly', `update server_lobby set style = '{"preset":"x"}' where server_id = $1`, [S]);
  await h.as(member);
  h.eq('member reads the look', (await h.q(`select style from server_lobby where server_id = $1`, [S]))[0]?.style, { preset: 'spotlight' });
}
