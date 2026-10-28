// 526: blocked links in bot output. Embeds and components on messages and ephemeral interaction replies run the same
// block list as message text, only where flag bot_link_guard is on. Base 024 plus the flags tables, with stand-ins for
// what later migrations add (messages.embeds/components, bot_interaction_replies, feature_on) and the 276 has_adult_link.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('526_bot_link_guard.sql');
// The live has_adult_link (276): cleans %2e, full-width dots and zero-width characters before matching.
const M276 = mig('276_link_loggers.sql');
const HAS_ADULT_LINK = /create or replace function public\.has_adult_link[\s\S]*?\n\$\$;/.exec(M276)[0];
const LINK_URL_PROBLEM = /create or replace function public\.link_url_problem[\s\S]*?\nend; \$\$;/.exec(M276)[0];

const STANDINS = String.raw`
alter table public.messages add column if not exists embeds jsonb;
alter table public.messages add column if not exists components jsonb;
create table if not exists public.bot_interaction_replies (
  id uuid primary key default gen_random_uuid(),
  interaction_id uuid not null default gen_random_uuid(),
  bot_id uuid not null default gen_random_uuid(),
  user_id uuid not null default gen_random_uuid(),
  channel_id uuid not null,
  message_id uuid not null default gen_random_uuid(),
  kind text not null,
  content text,
  embeds jsonb,
  created_at timestamptz not null default now()
);
create or replace function public.feature_on(k text, sid uuid) returns boolean language plpgsql stable security definer set search_path to 'public' as $function$
#variable_conflict use_column
begin
  return (select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false));
end;
$function$;
insert into public.blocked_domains (domain) values ('grabify.link'), ('cocainee.pro') on conflict do nothing;
create table if not exists public.link_hosts (domain text primary key, kind text not null);
insert into public.link_hosts (domain, kind) values ('bit.ly', 'shortener'), ('grabify.link', 'logger') on conflict do nothing;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`526 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(HAS_ADULT_LINK);
  await h.db.exec(LINK_URL_PROBLEM);
  await h.ok('526 runs', () => h.db.exec(MIG));
  await h.ok('526 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag is published', (await h.one(`select mode from feature_flags where key = 'bot_link_guard'`)).mode, 'everyone');
  // Test mode first (only the listed server), then published again further down.
  await h.q(`update feature_flags set mode = 'test' where key = 'bot_link_guard'`);

  const boss = await h.signup('b@x.com', 'boss');
  await h.admin();
  // Stage 24's new-account limit (one message every 3 seconds) isn't under test.
  await h.q(`update profiles set created_at = now() - interval '2 days' where id = $1`, [boss]);
  const server = async (name) => (await h.one(`insert into servers (name, owner_id) values ($1, $2) returning id`, [name, boss])).id;
  const channel = async (sid) => (await h.one(
    `insert into channels (kind, name, server_id, created_by) values ('text', 'general', $1, $2) returning id`, [sid, boss])).id;
  const on = await server('Test');
  const off = await server('Elsewhere');
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'bot_link_guard'`, [on]);
  const cOn = await channel(on);
  const cOff = await channel(off);

  const send = (cid, embeds, components = null) => h.q(
    `insert into messages (channel_id, author_id, content, embeds, components) values ($1, $2, 'hi', $3::jsonb, $4::jsonb) returning id`,
    [cid, boss, embeds && JSON.stringify(embeds), components && JSON.stringify(components)]);
  const refused = async (name, fn) => {
    let msg = null;
    try { await fn(); } catch (e) { msg = e.message; }
    h.eq(name, msg, 'Links to that site aren\'t allowed on Yapper.');
  };

  // link_strings: string values only, one per line.
  h.eq('link_strings joins values, not keys', (await h.one(`select public.link_strings('{"url": "a.com", "x": [1, "b.com"]}') v`)).v.split('\n').sort(), ['a.com', 'b.com']);
  h.eq('link_strings on a plain string', (await h.one(`select public.link_strings('"hey"') v`)).v, 'hey');
  h.eq('link_strings on null', (await h.one(`select public.link_strings(null) v`)).v, null);

  // Messages: every place a link can sit in an embed or component.
  const logger = 'https://yapin.cocainee.pro/authenticate?token=abc';
  await refused('embed url refused', () => send(cOn, [{ title: 'Verify', url: logger }]));
  await refused('embed description refused', () => send(cOn, [{ description: `Your secure sign-in link: ${logger}` }]));
  await refused('embed field refused', () => send(cOn, [{ fields: [{ name: 'Link', value: 'grabify.link/x' }] }]));
  await refused('embed image url refused', () => send(cOn, [{ image: { url: 'https://grabify.link/a.png' } }]));
  await refused('link button refused', () => send(cOn, [{ description: 'ok' }], [{ type: 1, components: [{ type: 2, style: 5, label: 'Sign in', url: logger }] }]));
  await refused('V2 text display refused', () => send(cOn, null, [{ type: 17, components: [{ type: 10, content: `go to ${logger}` }] }]));
  await refused('escaped newline before the site refused', () => send(cOn, [{ description: 'line one\ngrabify.link/x' }]));
  await refused('%2e dot refused', () => send(cOn, [{ description: 'grabify%2elink' }]));
  await refused('full-width dot refused', () => send(cOn, [{ description: 'grabify．link' }]));
  // Clickable urls also get the profile-link rules (link_url_problem).
  const button = (url) => [{ type: 1, components: [{ type: 2, style: 5, label: 'Sign in', url }] }];
  const said = async (name, fn, expected) => {
    let msg = null;
    try { await fn(); } catch (e) { msg = e.message; }
    h.eq(name, msg, expected);
  };
  await said('short link button refused', () => send(cOn, [{ description: 'ok' }], button('https://bit.ly/abc')),
    'Short links and IP loggers aren\'t allowed. Use the full link.');
  await said('bare IP embed url refused', () => send(cOn, [{ title: 'x', url: 'https://1.2.3.4/login' }]),
    'Use the site\'s name, not an IP address.');
  await said('localhost button refused', () => send(cOn, [{ description: 'ok' }], button('http://localhost:9283/callback')),
    'That link doesn\'t look like a real site.');
  await said('short link footer icon refused', () => send(cOn, [{ description: 'ok', footer: { text: 'f', icon_url: 'https://bit.ly/i.png' } }]),
    'Short links and IP loggers aren\'t allowed. Use the full link.');
  await said('short link typed in a description refused', () => send(cOn, [{ description: 'Your sign-in link: **https://bit.ly/abc**' }]),
    'Short links and IP loggers aren\'t allowed. Use the full link.');
  await said('bare IP in a V2 text display refused', () => send(cOn, null, [{ type: 17, components: [{ type: 10, content: 'go to <http://1.2.3.4:8080/x>' }] }]),
    'Use the site\'s name, not an IP address.');
  await h.ok('bare short link name in text still passes (same as message text)', () => send(cOn, [{ description: 'see bit.ly/abc' }]));
  await h.ok('markdown link to a normal site passes', () => send(cOn, [{ description: 'Read [the rules](https://www.yapin.gg/rules), then https://docs.example.com.' }]));
  await h.ok('ordinary embed and link button pass', () => send(cOn, [{ title: 'Rules', url: 'https://www.yapin.gg/rules' }],
    [{ type: 1, components: [{ type: 2, style: 5, label: 'Docs', url: 'https://docs.example.com' }] }]));
  await h.ok('no embeds passes', () => send(cOn, null));
  await h.ok('flag off in this server: not checked yet', () => send(cOff, [{ url: logger }]));

  // Edits: a changed embed is checked, an unchanged one isn't (an old bad embed doesn't lock other edits).
  const [{ id: mid }] = await send(cOn, [{ title: 'Fine' }]);
  await refused('edit to a blocked embed refused', () => h.q(`update messages set embeds = $2::jsonb where id = $1`,
    [mid, JSON.stringify([{ description: logger }])]));
  await h.q(`update feature_flags set servers = '{}' where key = 'bot_link_guard'`);
  await h.q(`update messages set embeds = $2::jsonb where id = $1`, [mid, JSON.stringify([{ description: logger }])]);
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'bot_link_guard'`, [on]);
  await h.ok('unchanged old embed does not block a components edit', () => h.q(`update messages set components = $2::jsonb where id = $1`,
    [mid, JSON.stringify([{ type: 1, components: [{ type: 2, style: 1, label: 'Ok', custom_id: 'ok' }] }])]));
  await refused('blocked link button on edit refused', () => h.q(`update messages set components = $2::jsonb where id = $1`,
    [mid, JSON.stringify([{ type: 1, components: [{ type: 2, style: 5, label: 'Go', url: logger }] }])]));

  // Ephemeral replies (bot_interaction_replies): content and embeds.
  const eph = (cid, content, embeds = null) => h.q(
    `insert into bot_interaction_replies (channel_id, kind, content, embeds) values ($1, 'ephemeral', $2, $3::jsonb)`,
    [cid, content, embeds && JSON.stringify(embeds)]);
  await refused('ephemeral content refused', () => eph(cOn, `Your secure sign-in link (valid for 15 minutes): ${logger}`));
  await refused('ephemeral embed refused', () => eph(cOn, '', [{ description: logger }]));
  await said('ephemeral short link refused', () => eph(cOn, 'Your secure sign-in link (valid for 15 minutes): https://bit.ly/x'),
    'Short links and IP loggers aren\'t allowed. Use the full link.');
  await h.ok('ordinary ephemeral passes', () => eph(cOn, 'You are verified! See https://www.yapin.gg', [{ title: 'Done' }]));
  await h.ok('ack row (no content) passes', () => h.q(`insert into bot_interaction_replies (channel_id, kind) values ($1, 'ack')`, [cOn]));
  await h.ok('ephemeral in a flag-off server not checked yet', () => eph(cOff, logger));

  // Published: on everywhere, DMs too (no server).
  await h.q(`update feature_flags set mode = 'everyone' where key = 'bot_link_guard'`);
  await refused('published: refused in any server', () => send(cOff, [{ url: logger }]));
  const dm = (await h.one(`insert into channels (kind, name, dm_key) values ('dm', 'dm', 'a:b') returning id`)).id;
  await refused('published: refused in a DM ephemeral', () => eph(dm, logger));
}
