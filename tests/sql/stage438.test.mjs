// 438: phone app push tokens and the push hook. Builds on 024 with the flag migrations, server mutes and stand-ins for
// the later columns and the Supabase-only bits (pg_net, vault).
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
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('438_mobile_app.sql');
  await h.db.exec(MIG);
  await h.ok('438 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'mobile_app'`)).mode, 'test');

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  const c = await h.signup('c@test.dev', 'carol');
  await h.q(`update profiles set created_at = now() - interval '2 days'`); // past the new-account message limits
  const TOK = (who) => `tok_${who.slice(0, 8)}_${'x'.repeat(20)}`;

  // ---- RLS: only your own rows ----
  await h.as(b);
  await h.ok('bob adds his own token', () => h.q(`insert into push_tokens (token, user_id, platform) values ($1, $2, 'android')`, [TOK(b), b]));
  await h.fails('bob cannot add a token for alice', `insert into push_tokens (token, user_id, platform) values ($1, $2, 'android')`, ['tok_for_alice_' + 'x'.repeat(20), a]);
  await h.fails('platform must be android or ios', `insert into push_tokens (token, user_id, platform) values ($1, $2, 'web')`, ['tok_web_' + 'x'.repeat(20), b]);
  await h.fails('short tokens are refused', `insert into push_tokens (token, user_id, platform) values ('short', $1, 'ios')`, [b]);
  await h.ok('bob refreshes his token row', () => h.q(`update push_tokens set updated_at = now() where token = $1`, [TOK(b)]));
  await h.as(a);
  h.eq('alice sees no tokens of bob', (await h.q(`select token from push_tokens`)).length, 0);
  h.eq("alice cannot delete bob's token", (await h.q(`delete from push_tokens where token = $1 returning token`, [TOK(b)])).length, 0);
  h.eq("alice cannot move bob's token to herself", (await h.q(`update push_tokens set user_id = $1 where token = $2 returning token`, [a, TOK(b)])).length, 0);
  await h.as(null);
  await h.fails('anon cannot read tokens', `select token from push_tokens`);
  await h.admin();
  h.eq("bob's token is still there", (await h.q(`select token from push_tokens where user_id = $1`, [b])).length, 1);

  // ---- The hook: DMs ----
  const calls = () => h.q(`select body from net_calls order by id`);
  const reset = () => h.q(`delete from net_calls`);
  const dm = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'a-b') returning id`)).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, a, b]);
  const say = (cid, who, text) => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, who, text]);

  await say(dm, a, 'hi bob');
  h.eq('no vault secrets yet: nothing is sent', (await calls()).length, 0);
  await h.q(`insert into vault.decrypted_secrets values ('push_url', 'https://www.yapper.website/'), ('push_secret', 's3cret')`);

  await say(dm, a, 'hi bob again');
  let got = await calls();
  h.eq('a DM posts one push request', got.length, 1);
  h.eq('to the one with a token', got[0].body.to, [b]);
  h.eq('with the channel and text', [got[0].body.channel_id, got[0].body.content, got[0].body.server_id, got[0].body.attachment], [dm, 'hi bob again', null, false]);
  const hdr = await h.one(`select headers, url from net_calls`);
  h.eq('bearer secret and the send route', [hdr.headers.Authorization, hdr.url], ['Bearer s3cret', 'https://www.yapper.website/api/push/send']);
  await reset();

  await say(dm, b, 'hi alice');
  h.eq('alice has no token: no request', (await calls()).length, 0);

  await say(dm, a, '↪ Forwarded\nsomething');
  h.eq('forwarded messages do not push', (await calls()).length, 0);

  await h.q(`insert into presence (user_id, pref) values ($1, 'dnd')`, [b]);
  await say(dm, a, 'you there?');
  h.eq('do not disturb: no push', (await calls()).length, 0);
  await h.q(`update presence set pref = 'online' where user_id = $1`, [b]);

  await h.q(`insert into blocks (blocker, blocked) values ($1, $2)`, [b, a]);
  await say(dm, a, 'blocked?');
  h.eq('blocked author: no push', (await calls()).length, 0);
  await h.q(`delete from blocks where blocker = $1`, [b]);

  await h.q(`insert into channel_reads (user_id, channel_id, muted) values ($1, $2, true)`, [b, dm]);
  await say(dm, a, 'muted?');
  h.eq('muted DM: no push', (await calls()).length, 0);
  await h.q(`update channel_reads set muted = false where user_id = $1 and channel_id = $2`, [b, dm]);

  await say(dm, a, 'back to normal');
  h.eq('and pushes again once those are lifted', (await calls()).length, 1);
  await reset();

  // ---- The hook: servers ----
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Push Test', $1) returning id`, [a])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, a, b]);
  const gen = (await h.one(`insert into channels (kind, name, server_id) values ('text', 'general', $1) returning id`, [sid])).id;

  await say(gen, a, 'hello everyone');
  h.eq('a plain server message pushes nobody', (await calls()).length, 0);

  await say(gen, a, `hey <@${b}> look`);
  got = await calls();
  h.eq('an @mention pushes the mentioned member', got.map((r) => r.body.to), [[b]]);
  h.eq('with the server id', got[0].body.server_id, sid);
  await reset();

  await say(gen, a, `hey <@${c}> look`);
  h.eq('mentioning someone who is not a member pushes nobody', (await calls()).length, 0);

  const bobMsg = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'mine') returning id`, [gen, b])).id;
  await h.q(`insert into messages (channel_id, author_id, content, reply_to_id) values ($1, $2, 'replying', $3)`, [gen, a, bobMsg]);
  h.eq('a reply pushes the person replied to', (await calls()).map((r) => r.body.to), [[b]]);
  await reset();

  await h.q(`insert into messages (channel_id, author_id, content, reply_to_id) values ($1, $2, 'replying to myself', $3)`, [gen, b, bobMsg]);
  h.eq('never yourself', (await calls()).length, 0);

  const role = (await h.one(`insert into roles (server_id, name) values ($1, 'Mods') returning id`, [sid])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, b, role]);
  await say(gen, a, `<@&${role}> ping`);
  h.eq('a role mention pushes its members', (await calls()).map((r) => r.body.to), [[b]]);
  await reset();

  await h.q(`insert into server_mutes (user_id, server_id) values ($1, $2)`, [b, sid]);
  await say(gen, a, `<@${b}> muted server`);
  h.eq('a muted server never pushes', (await calls()).length, 0);
  await h.q(`delete from server_mutes where user_id = $1`, [b]);

  const priv = (await h.one(`insert into channels (kind, name, server_id, private) values ('text', 'staff', $1, true) returning id`, [sid])).id;
  await say(priv, a, `<@${b}> secret`);
  h.eq('a private channel bob cannot see pushes nobody', (await calls()).length, 0);

  await h.q(`update feature_flags set mode = 'off' where key = 'mobile_app'`);
  await say(dm, a, 'flag off');
  h.eq('flag off: nothing at all', (await calls()).length, 0);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'mobile_app'`);
  await say(dm, a, 'flag on for everyone');
  h.eq('flag on for everyone: pushes', (await calls()).length, 1);
}
