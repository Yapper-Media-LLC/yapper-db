// 355: bot gateway functions (flag bot_gateway). Starts from stage 24 (+ flags 031/041) with stand-ins for bots,
// bot_hosting, bot_events, presence/bot_presence and the vault secret. Then 355 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const SECRET = 'rt-secret-for-tests-0123456789';
const STANDINS = `
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (name text primary key, decrypted_secret text);
insert into vault.decrypted_secrets values ('gw_secret', '${SECRET}'), ('rt_secret', 'the-publish-secret-not-this-one') on conflict do nothing;
create table if not exists public.bots (id uuid primary key, owner_id uuid not null, name text not null, token_hash text unique, last_poll_at timestamptz);
create table if not exists public.bot_hosting (bot_id uuid primary key, host_token_hash text, blocked boolean not null default false,
  want_running boolean not null default false, until timestamptz, free_slot boolean not null default false);
create table if not exists public.bot_events (id bigserial primary key, bot_id uuid not null, type text not null, data jsonb not null default '{}', created_at timestamptz not null default clock_timestamp());
create index if not exists bot_events_bot_idx on public.bot_events (bot_id, id);
create table if not exists public.bot_presence_log (bid uuid, at timestamptz default now());
create or replace function public.bot_presence(bid uuid, st text default null, act jsonb default null) returns void
language sql security definer set search_path = public as $$ insert into public.bot_presence_log (bid) values (bid); $$;
`;

export default async function (h) {
  await h.db.exec(STANDINS);
  const mig = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '355_bot_gateway.sql'), 'utf8');
  await h.db.exec(mig);
  await h.ok('re-runs cleanly', () => h.db.exec(mig));
  h.eq('flag in test mode', (await h.one(`select mode from feature_flags where key = 'bot_gateway'`)).mode, 'test');

  const owner = await h.signup('owner@test.dev', 'owner');
  const other = await h.signup('other@test.dev', 'other');
  const tester = await h.signup('tester@test.dev', 'tester');
  const b1 = await h.signup('b1@test.dev', 'botone');
  const b2 = await h.signup('b2@test.dev', 'bottwo');
  const b3 = await h.signup('b3@test.dev', 'botthree');
  const hash = (c) => c.repeat(64);
  await h.as(tester);
  const S = (await h.one(`select create_server('Test', null) id`)).id;
  await h.admin();
  await h.q(`update feature_flags set users = array[$1::uuid], servers = array[$2::uuid] where key = 'bot_gateway'`, [owner, S]);
  await h.q(`insert into bots (id, owner_id, name, token_hash) values ($1, $2, 'one', $3), ($4, $5, 'two', $6), ($7, $8, 'three', null)`,
    [b1, owner, hash('a'), b2, other, hash('b'), b3, tester]);
  await h.q(`insert into bot_hosting (bot_id, host_token_hash, want_running, until) values ($1, $2, true, now() + interval '10 days')`, [b3, hash('c')]);
  for (let i = 0; i < 3; i++) await h.q(`insert into bot_events (bot_id, type, data) values ($1, 'message', $2)`, [b1, JSON.stringify({ n: i })]);
  await h.q(`insert into bot_events (bot_id, type) values ($1, 'member_join')`, [b2]);

  // Wrong or missing secret: refused, for anon too.
  await h.as(null);
  await h.fails('auth without the secret', `select gateway_bot_auth('nope-nope-nope-nope', $1)`, [hash('a')]);
  await h.fails('events without the secret', `select * from gateway_bot_events(null, array[$1::uuid], array[0::bigint])`, [b1]);
  await h.fails('presence without the secret', `select gateway_bot_presence('', array[$1::uuid])`, [b1]);
  await h.fails('the publish secret is not the gateway secret', `select gateway_bot_auth('the-publish-secret-not-this-one', $1)`, [hash('a')]);
  await h.fails('secret check is not callable', `select gateway_secret_ok($1)`, [SECRET]);

  // Token lookup + flag per owner.
  const auth = async (hh) => (await h.one(`select gateway_bot_auth($1, $2) a`, [SECRET, hh])).a;
  const a1 = await auth(hash('a'));
  h.eq('bot token finds the bot, flag on for listed owner', [a1.id, a1.owner_id, a1.gateway, a1.hosted], [b1, owner, true, false]);
  h.eq('newest is the latest event id', a1.newest > 0, true);
  h.eq('flag off for other owners', (await auth(hash('b'))).gateway, false);
  const a3 = await auth(hash('c'));
  h.eq('hosting token finds its bot, flag on via test server', [a3.id, a3.hosted, a3.gateway, a3.newest], [b3, true, true, 0]);
  h.eq('unknown token is null', await auth(hash('d')), null);
  h.eq('junk hash is null', await auth('not-a-hash'), null);
  await h.admin();
  await h.q(`update bot_hosting set blocked = true where bot_id = $1`, [b3]);
  await h.as(null);
  h.eq('blocked hosting token is null', await auth(hash('c')), null);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'bot_gateway'`);
  await h.as(null);
  h.eq('everyone mode: on for any owner', (await auth(hash('b'))).gateway, true);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'bot_gateway'`);
  await h.as(null);
  h.eq('off mode: off for listed owner too', (await auth(hash('a'))).gateway, false);

  // Batched events: per-bot cursors, own events only, id order, limit.
  const ev = async (bots, after, lim = 100) => h.q(`select bot_id, id, type from gateway_bot_events($1, $2::uuid[], $3::bigint[], $4)`, [SECRET, bots, after, lim]);
  const all = await ev([b1, b2], [0, 0]);
  h.eq('each bot gets only its own rows', all.map((r) => [r.bot_id === b1 ? 'b1' : 'b2', r.type]).sort(), [['b1', 'message'], ['b1', 'message'], ['b1', 'message'], ['b2', 'member_join']]);
  const firstId = all.filter((r) => r.bot_id === b1)[0].id;
  h.eq('ids in order per bot', all.filter((r) => r.bot_id === b1).map((r) => r.id).every((v, i, a) => !i || a[i - 1] < v), true);
  h.eq('cursor skips seen events', (await ev([b1], [firstId])).length, 2);
  h.eq('limit per bot', (await ev([b1, b2], [0, 0], 1)).length, 2);
  h.eq('empty list is fine', (await ev([], [])).length, 0);
  h.eq('functions are volatile (POST only in PostgREST)', (await h.q(`select provolatile v from pg_proc where proname in ('gateway_bot_auth', 'gateway_bot_events', 'gateway_bot_presence') order by proname`)).map((r) => r.v), ['v', 'v', 'v']);
  await h.fails('mismatched arrays refused', `select * from gateway_bot_events($1, array[$2::uuid], '{}'::bigint[])`, [SECRET, b1]);

  // Presence for connected bots.
  h.eq('presence counts known bots only', (await h.one(`select gateway_bot_presence($1, array[$2::uuid, $3::uuid]) n`, [SECRET, b1, other])).n, 1);
  await h.admin();
  h.eq('presence stamps last_poll_at and calls bot_presence',
    (await h.one(`select (select last_poll_at is not null from bots where id = $1) polled, (select count(*)::int from bot_presence_log where bid = $1) n`, [b1])),
    { polled: true, n: 1 });

  // Signed-in users can't call them either (only anon is granted, and still needs the secret).
  await h.as(owner);
  await h.fails('authenticated role is not granted', `select gateway_bot_auth($1, $2)`, [SECRET, hash('a')]);
  await h.admin();
}
