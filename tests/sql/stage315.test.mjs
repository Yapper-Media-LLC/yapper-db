// 315: Components V2 for bots. bot_api_send / bot_api_edit / press_button come from the migration itself; the things
// they call (rate-limit gate, flags, pushes) are small stand-ins. Checks: the flag gate, no content/embeds next to a
// layout, a V2 message stays V2 on edit, old button messages work as before, and clicks find buttons nested anywhere.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '315_bot_components_v2.sql'), 'utf8');

const STANDINS = `
alter table public.messages disable trigger user;
alter table public.messages add column if not exists reply_to_id uuid;
alter table public.messages add column if not exists embeds jsonb;
alter table public.messages add column if not exists components jsonb;
alter table public.profiles add column if not exists muted_until timestamptz;
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text,
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.flag_off (key text primary key);
create table if not exists public.bots (id uuid primary key, webhook_url text, webhook_secret text);
create table if not exists public.bot_interactions (id uuid primary key default gen_random_uuid(), token text, bot_id uuid,
  message_id uuid, channel_id uuid, server_id uuid, user_id uuid, custom_id text, created_at timestamptz not null default now());
create table if not exists public.bot_interaction_replies (id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now());
create table if not exists public.pushes (bot_id uuid, kind text, payload jsonb);
grant select on public.pushes to authenticated;
create schema if not exists extensions;
grant usage on schema extensions to authenticated;
create or replace function extensions.digest(t text, alg text) returns bytea language sql immutable as $$ select convert_to(t, 'UTF8') $$;
create or replace function extensions.gen_random_bytes(n int) returns bytea language sql as $$ select decode(repeat('ab', n), 'hex') $$;
create or replace function public.bot_channel_visible(bid uuid, cid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.bot_send_gate(bid uuid, cid uuid, reply uuid) returns void language sql as $$ select $$;
create or replace function public.server_timed_out(sid uuid, uid uuid) returns timestamptz language sql stable as $$ select null::timestamptz $$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.flag_off where key = k) $$;
create or replace function public.bot_push(bid uuid, url text, secret text, kind text, payload jsonb) returns void language sql security definer set search_path = public as $$
  insert into public.pushes values (bid, kind, payload) $$;
`;

const V2 = (extra = []) => JSON.stringify([
  { type: 17, id: 1, accent_color: 5793266, components: [
    { type: 10, id: 2, content: '# Hi' },
    { type: 9, id: 3, components: [{ type: 10, id: 4, content: 'Pick one' }], accessory: { type: 2, id: 5, style: 'primary', label: 'Go', custom_id: 'go' } },
    { type: 14, id: 6, divider: true, spacing: 1 },
    { type: 1, id: 7, components: [{ type: 2, id: 8, style: 'danger', label: 'No', custom_id: 'no', disabled: true }] },
  ] },
  ...extra,
]);
const ROWS = JSON.stringify([{ type: 'row', components: [{ type: 'button', style: 'primary', label: 'Old', custom_id: 'old' }] }]);

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('315 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag row is test-only on the test server and Antic', await h.one(`select mode, servers, users from feature_flags where key = 'bot_components_v2'`),
    { mode: 'test', servers: ['00000000-0000-4000-8000-00000000b001'], users: ['00000000-0000-4000-8000-00000000a001'] });
  h.eq('components_v2 tells layouts from old rows', await h.one(`select components_v2($1::jsonb) v2, components_v2($2::jsonb) old, components_v2(null) nul`, [V2(), ROWS]),
    { v2: true, old: false, nul: false });

  const amy = await h.signup('amy@test.dev', 'amy');
  const botId = await h.signup('bot@test.dev', 'robot');
  await h.admin();
  await h.q(`insert into bots (id) values ($1)`, [botId]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, amy, botId]);
  const ch = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;

  // Sending.
  const v2 = (await h.one(`select (bot_api_send($1, $2, '', null, null, $3::jsonb)).id`, [botId, ch, V2()])).id;
  h.eq('a V2 message is stored as sent', (await h.one(`select content, embeds, components_v2(components) v2 from messages where id = $1`, [v2])), { content: '', embeds: null, v2: true });
  await h.fails('no content next to a layout', `select bot_api_send($1, $2, 'hello', null, null, $3::jsonb)`, [botId, ch, V2()]);
  await h.fails('no embeds next to a layout', `select bot_api_send($1, $2, '', null, '[{"title":"x"}]'::jsonb, $3::jsonb)`, [botId, ch, V2()]);
  const old = (await h.one(`select (bot_api_send($1, $2, 'old style', null, null, $3::jsonb)).id`, [botId, ch, ROWS])).id;
  await h.fails('old buttons still need content', `select bot_api_send($1, $2, '', null, null, $3::jsonb)`, [botId, ch, ROWS]);
  const big = JSON.stringify(Array.from({ length: 41 }, (_, i) => ({ type: 10, id: i + 1, content: 'x' })));
  await h.fails('the shape check caps top-level components at 40', `select bot_api_send($1, $2, '', null, null, $3::jsonb)`, [botId, ch, big]);

  // Editing.
  await h.ok('a V2 message takes a new layout', () => h.q(`select bot_api_edit($1, $2, null, null, false, $3::jsonb, true)`, [botId, v2, V2([{ type: 14, id: 9 }])]));
  await h.fails('a V2 message stays V2 (old rows)', `select bot_api_edit($1, $2, 'now text', null, false, $3::jsonb, true)`, [botId, v2, ROWS]);
  await h.fails('a V2 message stays V2 (components removed)', `select bot_api_edit($1, $2, 'now text', null, false, null, true)`, [botId, v2]);
  await h.fails('a V2 message gets no content', `select bot_api_edit($1, $2, 'text', null, false, null, false)`, [botId, v2]);
  await h.fails('an old message cannot turn V2 with its content on', `select bot_api_edit($1, $2, null, null, false, $3::jsonb, true)`, [botId, old, V2()]);
  await h.ok('an old message can turn V2 when its content goes', () => h.q(`select bot_api_edit($1, $2, '', null, false, $3::jsonb, true)`, [botId, old, V2()]));
  const old2 = (await h.one(`select (bot_api_send($1, $2, 'old style', null, null, $3::jsonb)).id`, [botId, ch, ROWS])).id;
  await h.ok('old messages edit as before', () => h.q(`select bot_api_edit($1, $2, 'edited', null, false, null, false)`, [botId, old2]));

  // Clicking, as amy.
  await h.as(amy);
  await h.ok('a section accessory button reaches the bot', () => h.q(`select press_button($1, 'go')`, [v2]));
  await h.fails('a disabled button inside a container does not', `select press_button($1, 'no')`, [v2]);
  await h.fails('a made-up custom_id does not', `select press_button($1, 'nope')`, [v2]);
  await h.ok('old row buttons still work', () => h.q(`select press_button($1, 'old')`, [old2]));
  await h.admin();
  h.eq('the bot got both clicks', (await h.q(`select payload ->> 'custom_id' c from pushes order by c`)).map((r) => r.c), ['go', 'old']);

  // Flag off: V2 is refused, old buttons aren't affected.
  await h.q(`insert into flag_off values ('bot_components_v2') on conflict do nothing`);
  await h.fails('flag off: V2 sends are refused', `select bot_api_send($1, $2, '', null, null, $3::jsonb)`, [botId, ch, V2()]);
  await h.fails('flag off: V2 edits are refused', `select bot_api_edit($1, $2, null, null, false, $3::jsonb, true)`, [botId, v2, V2()]);
  await h.ok('flag off: old buttons still send', () => h.q(`select bot_api_send($1, $2, 'hi', null, null, $3::jsonb)`, [botId, ch, ROWS]));
  await h.q(`insert into flag_off values ('bot_buttons') on conflict do nothing`);
  await h.as(amy);
  await h.fails('both flags off: V2 buttons do nothing', `select press_button($1, 'go')`, [v2]);
  await h.admin();
}
