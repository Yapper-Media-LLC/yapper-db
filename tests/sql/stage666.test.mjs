// 666: per-channel notification levels and timed mutes (flag channel_notify). The table is read-only to its owner,
// the RPCs check flag, membership and access, and the push hook adds "all" people (rate capped) and drops "none"
// people from @mention pushes. Built on 438 (push hook) with its stand-ins.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '038_server_mutes.sql'];

const STANDINS = `
alter table public.channels add column if not exists category_id uuid;
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid, category_id uuid, role_id uuid);
create table if not exists public.presence (user_id uuid primary key, pref text);
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (name text primary key, decrypted_secret text);
create schema if not exists net;
create table if not exists public.net_calls (id serial primary key, url text, headers jsonb, body jsonb);
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language plpgsql as $$
begin insert into public.net_calls (url, headers, body) values (url, headers, body); return 1; end $$;
`;

export default async function (h) {
  const MIG = mig('666_channel_notify.sql');
  for (const bad of ['drop ', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`666 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('438_mobile_app.sql'));
  await h.ok('666 runs', () => h.db.exec(MIG));
  await h.ok('666 re-runs cleanly', () => h.db.exec(MIG));
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'channel_notify'`);
  h.eq('flag is test mode', flag.mode, 'test');
  h.eq('flag test server', flag.servers, ['00000000-0000-4000-8000-00000000b001']);
  h.eq('flag test user', flag.users, ['00000000-0000-4000-8000-00000000a001']);
  h.eq('RLS on notify_settings', (await h.one(`select relrowsecurity from pg_class where oid = 'public.notify_settings'::regclass`)).relrowsecurity, true);

  const a = await h.signup('a666@test.dev', 'alice666');
  const b = await h.signup('b666@test.dev', 'bob666');
  const c = await h.signup('c666@test.dev', 'carol666');
  const out = await h.signup('o666@test.dev', 'out666');
  await h.q(`update profiles set created_at = now() - interval '2 days'`);
  const TOK = (who) => `tok_${who.slice(0, 8)}_${'x'.repeat(20)}`;
  for (const u of [a, b, c]) await h.q(`insert into push_tokens (token, user_id, platform) values ($1, $2, 'android')`, [TOK(u), u]);
  await h.q(`insert into vault.decrypted_secrets values ('push_url', 'https://www.yapper.website/'), ('push_secret', 's3cret')`);

  const SID = '00000000-0000-4000-8000-00000000b001';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'HQ', $2)`, [SID, a]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4) on conflict do nothing`, [SID, a, b, c]);
  const verify = (await h.one(`insert into channels (kind, name, server_id) values ('text', 'verify', $1) returning id`, [SID])).id;
  const ann = (await h.one(`insert into channels (kind, name, server_id) values ('text', 'announcements', $1) returning id`, [SID])).id;
  const priv = (await h.one(`insert into channels (kind, name, server_id, private) values ('text', 'staff', $1, true) returning id`, [SID])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('Elsewhere', $1) returning id`, [a])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [other, a, b]);
  const otherCh = (await h.one(`insert into channels (kind, name, server_id) values ('text', 'general', $1) returning id`, [other])).id;

  // ---- RPCs and RLS ----
  await h.as(b);
  await h.ok('bob picks All messages for #verify', () => h.q(`select set_notify_level($1, $2, 'all')`, [SID, verify]));
  await h.ok('bob picks Nothing for #announcements', () => h.q(`select set_notify_level($1, $2, 'none')`, [SID, ann]));
  await h.ok('bob changes his mind (upsert)', () => h.q(`select set_notify_level($1, $2, 'none')`, [SID, ann]));
  await h.fails('unknown level is refused', `select set_notify_level($1, $2, 'loud')`, [SID, verify]);
  await h.fails('a private channel bob cannot see is refused', `select set_notify_level($1, $2, 'all')`, [SID, priv]);
  await h.fails('a channel from another server is refused', `select set_notify_level($1, $2, 'all')`, [SID, otherCh]);
  await h.fails('flag off for that server: refused', `select set_notify_level($1, $2, 'all')`, [other, otherCh]);
  await h.fails('bob cannot write the table directly', `insert into notify_settings (user_id, server_id, channel_id, level) values ($1, $2, $3, 'all')`, [b, SID, ann]);
  h.eq('bob cannot change rows directly', (await h.q(`update notify_settings set level = 'all' returning user_id`).catch(() => [])).length, 0);
  h.eq('bob sees his two rows', (await h.q(`select level from my_notify_settings() order by level`)).map((r) => r.level), ['all', 'none']);
  await h.as(out);
  await h.fails('a non-member cannot set anything', `select set_notify_level($1, $2, 'all')`, [SID, verify]);
  await h.fails('a non-member cannot mute', `select set_notify_mute($1, 15)`, [verify]);
  h.eq("outsider sees nobody's rows", (await h.q(`select * from notify_settings`)).length, 0);
  await h.as(null);
  await h.fails('anon cannot read settings', `select * from notify_settings`);
  await h.fails('anon cannot call the RPC', `select set_notify_level($1, $2, 'all')`, [SID, verify]);

  // ---- Push hook ----
  await h.admin();
  const calls = () => h.q(`select body from net_calls order by id`);
  const reset = () => h.q(`delete from net_calls`);
  const say = (cid, who, text) => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, who, text]);
  await reset();

  await say(verify, a, 'new person here');
  let got = await calls();
  h.eq('All messages: a plain message pushes bob', got.map((r) => r.body.to), [[b]]);
  await reset();
  await say(verify, a, 'and again');
  h.eq('the next one within 10 s is rate capped', (await calls()).length, 0);
  await h.q(`update notify_settings set last_push_at = now() - interval '11 seconds' where user_id = $1`, [b]);
  await say(verify, a, `<@${c}> and a ping`);
  got = await calls();
  h.eq('after the window: bob (all) and carol (mention) together', got.map((r) => [...r.body.to].sort()), [[b, c].sort()]);
  await reset();
  await say(verify, b, 'my own message');
  h.eq('never your own message', (await calls()).length, 0);

  await say(ann, a, `<@${b}> big news`);
  h.eq('Nothing: an @mention does not push', (await calls()).length, 0);
  await say(ann, a, 'plain news');
  h.eq('a plain message in a mentions channel pushes nobody', (await calls()).length, 0);

  // Server default
  await h.as(c);
  await h.ok('carol sets the server default to All', () => h.q(`select set_notify_level($1, null, 'all')`, [SID]));
  await h.ok('carol keeps #announcements at Only @mentions', () => h.q(`select set_notify_level($1, $2, 'mentions')`, [SID, ann]));
  await h.admin();
  await say(ann, a, 'quiet for carol');
  h.eq("a channel level beats the server default", (await calls()).length, 0);
  await h.q(`update notify_settings set last_push_at = null`);
  await say(verify, a, 'loud for both');
  got = await calls();
  h.eq('server default All pushes carol, channel All pushes bob', got.map((r) => [...r.body.to].sort()), [[b, c].sort()]);
  await reset();

  // Mute
  await h.q(`update notify_settings set last_push_at = null`);
  await h.as(b);
  const until = (await h.one(`select set_notify_mute($1, 60) as u`, [verify])).u;
  h.eq('a 1 h mute returns its end', !!until, true);
  h.eq('and sets the old muted flag', (await h.one(`select muted from channel_reads where user_id = $1 and channel_id = $2`, [b, verify])).muted, true);
  await h.fails('more than 24 h is refused', `select set_notify_mute($1, 5000)`, [verify]);
  await h.admin();
  await say(verify, a, 'muted for bob');
  h.eq('a muted channel stops All pushes (carol still gets hers)', (await calls()).map((r) => r.body.to), [[c]]);
  await reset();
  await h.q(`update notify_settings set muted_until = now() - interval '1 minute' where user_id = $1 and channel_id = $2`, [b, verify]);
  await h.q(`update notify_settings set last_push_at = null`);
  await say(verify, a, 'mute ran out');
  h.eq('an expired mute pushes again', (await calls()).map((r) => [...r.body.to].sort()), [[b, c].sort()]);
  await reset();
  await h.as(b);
  h.eq('loading reports the lifted mute', (await h.q(`select lifted from my_notify_settings() where channel_id = $1`, [verify])).map((r) => r.lifted), [true]);
  h.eq('only once', (await h.q(`select lifted from my_notify_settings() where channel_id = $1`, [verify])).map((r) => r.lifted), [false]);
  h.eq('loading lifts the expired mute', (await h.one(`select muted from channel_reads where user_id = $1 and channel_id = $2`, [b, verify])).muted, false);
  await h.ok('mute until I turn it back on', () => h.q(`select set_notify_mute($1, null)`, [verify]));
  h.eq('no end time', (await h.one(`select muted_until from my_notify_settings() where channel_id = $1`, [verify])).muted_until, null);
  await h.ok('unmute', () => h.q(`select set_notify_mute($1, 0)`, [verify]));
  h.eq('unmuted', (await h.one(`select muted from channel_reads where user_id = $1 and channel_id = $2`, [b, verify])).muted, false);

  // The old bell after a timed mute ran out: its end time goes, so the next load doesn't lift the new mute.
  await h.ok('a 15 min mute', () => h.q(`select set_notify_mute($1, 15)`, [verify]));
  await h.admin();
  await h.q(`update notify_settings set muted_until = now() - interval '1 minute' where user_id = $1 and channel_id = $2`, [b, verify]);
  await h.as(b);
  await h.ok('bell mutes again', () => h.q(`select set_muted($1, true)`, [verify]));
  h.eq('end time cleared', (await h.one(`select muted_until from notify_settings where channel_id = $1`, [verify])).muted_until, null);
  await h.q(`select * from my_notify_settings()`);
  h.eq('still muted after a load', (await h.one(`select muted from channel_reads where user_id = $1 and channel_id = $2`, [b, verify])).muted, true);
  await h.ok('bell unmutes', () => h.q(`select set_muted($1, false)`, [verify]));

  // A channel push stamps the channel row only, not the server default.
  await h.admin();
  await h.q(`update notify_settings set last_push_at = null`);
  await h.q(`insert into notify_settings (user_id, server_id, channel_id, level) values ($1, $2, null, 'all')`, [b, SID]);
  await say(verify, a, 'stamp check');
  await reset();
  h.eq("bob's #verify row stamped, his server default not",
    (await h.q(`select channel_id is null as dflt, last_push_at is not null as stamped from notify_settings where user_id = $1 and level = 'all' order by 1`, [b])).map((r) => [r.dflt, r.stamped]),
    [[false, true], [true, false]]);
  // Someone without a phone never fills the list.
  await h.q(`delete from push_tokens where user_id = $1`, [c]);
  await h.q(`update notify_settings set last_push_at = null`);
  await say(verify, a, 'no phone for carol');
  h.eq('only people with a phone are picked', (await calls()).map((r) => r.body.to), [[b]]);
  await reset();
  await h.q(`insert into push_tokens (token, user_id, platform) values ($1, $2, 'android')`, [TOK(c), c]);
  await h.q(`update notify_settings set last_push_at = null`);

  // Server mute and DND still win; flag off ignores the rows.
  await h.admin();
  await h.q(`update notify_settings set last_push_at = null`);
  await h.q(`insert into server_mutes (user_id, server_id) values ($1, $2)`, [b, SID]);
  await h.q(`insert into presence (user_id, pref) values ($1, 'dnd')`, [c]);
  await say(verify, a, 'server muted');
  h.eq('server mute and DND still win', (await calls()).length, 0);
  await h.q(`delete from server_mutes where user_id = $1`, [b]);
  await h.q(`delete from presence where user_id = $1`, [c]);
  await h.q(`update feature_flags set mode = 'off' where key = 'channel_notify'`);
  await say(verify, a, 'flag off');
  h.eq('flag off: All does nothing', (await calls()).length, 0);
  await say(ann, a, `<@${b}> flag off ping`);
  h.eq('flag off: Nothing no longer blocks @mentions', (await calls()).map((r) => r.body.to), [[b]]);
  await h.q(`update feature_flags set mode = 'test' where key = 'channel_notify'`);
}
