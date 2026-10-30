// 670: voice activity log (flag voice_activity_log). The webhook writer is service role only, pairs a leave and a join
// into one move (either order), folds reconnects away, skips DM calls and servers without the flag. Only View Audit
// Log / Manage Server can read it, and only for voice channels they can see. Nobody can write rows by hand. Voice
// mutes and bans land in the audit log; voice_mod_log checks Move Members and rank before logging a disconnect or move.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '670_voice_activity_log.sql'), 'utf8');

const STANDINS = String.raw`
create table public.t670 (k text primary key);
create table if not exists public.t670_audit (sid uuid, actor uuid, act text, tid uuid, extra jsonb);
create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb) returns void
  language sql security definer set search_path = public as $$ insert into public.t670_audit values (sid, auth.uid(), act, tid, extra) $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
      or exists (select 1 from public.t670 where k = sid::text || ':' || auth.uid()::text || ':' || perm) $$;
create or replace function public.outranks(sid uuid, target uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.t670 where k = 'outranks:' || auth.uid()::text || ':' || target::text) $$;
create or replace function public.is_staff() returns boolean language sql stable as $$ select false $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.t670 where k = 'staff:' || uid::text) $$;
create or replace function public.can_access_channel(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.t670 where k = 'hidden:' || cid::text) $$;
create table if not exists public.bots (id uuid primary key references public.profiles (id) on delete cascade);
create or replace function public.bot_channel_visible(bid uuid, cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.t670 where k = 'hidden:' || cid::text) $$;
create table if not exists public.bot_servers (bot_id uuid references public.bots (id) on delete cascade,
  server_id uuid references public.servers (id) on delete cascade, primary key (bot_id, server_id));
create table if not exists public.server_voice_mutes (server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade, until timestamptz not null, primary key (server_id, user_id));
create table if not exists public.server_voice_bans (server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade, until timestamptz, reason text not null default '',
  primary key (server_id, user_id));
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`670 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('670 runs', () => h.db.exec(MIG));
  await h.ok('670 re-runs cleanly', () => h.db.exec(MIG));
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'voice_activity_log'`);
  h.eq('flag is test mode', flag.mode, 'test');
  h.eq('flag test server', flag.servers, ['00000000-0000-4000-8000-00000000b001']);
  h.eq('flag test user', flag.users, ['00000000-0000-4000-8000-00000000a001']);
  h.eq('RLS on voice_activity', (await h.one(`select relrowsecurity r from pg_class where oid = 'public.voice_activity'::regclass`)).r, true);

  const owner = await h.signup('own670@x.test', 'own670');
  const mod = await h.signup('mod670@x.test', 'mod670');
  const reader = await h.signup('read670@x.test', 'read670');
  const mem = await h.signup('mem670@x.test', 'mem670');
  const mem2 = await h.signup('mem2_670@x.test', 'mem2_670');
  const stranger = await h.signup('out670@x.test', 'out670');
  const SID = '00000000-0000-4000-8000-00000000b001';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Test', $2)`, [SID, owner]);
  const OFF = (await h.one(`insert into servers (name, owner_id) values ('Off', $1) returning id`, [owner])).id;
  await h.q(`insert into server_members (server_id, user_id) select $1, unnest($2::uuid[]) on conflict do nothing`, [SID, [owner, mod, reader, mem, mem2]]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [OFF, owner, mem]);
  const vc = async (s, name) => (await h.one(`insert into channels (server_id, kind, name, created_by) values ($1, 'voice', $2, $3) returning id`, [s, name, owner])).id;
  const A = await vc(SID, 'A');
  const B = await vc(SID, 'B');
  const C = await vc(SID, 'C');
  const SECRET = await vc(SID, 'Secret');
  const OFFV = await vc(OFF, 'offvc');
  const TEXT = (await h.one(`insert into channels (server_id, kind, name, created_by) values ($1, 'text', 'chat', $2) returning id`, [SID, owner])).id;
  await h.q(`insert into t670 (k) values ($1), ($2), ($3), ($4)`, [
    `${SID}:${reader}:view_audit_log`, `${SID}:${mod}:move_members`, `outranks:${mod}:${mem}`, `hidden:${SECRET}`,
  ]);

  // ---------- writing (service role) ----------
  await h.as(mem);
  await h.fails('a member cannot call the writer', `select voice_activity_add($1, $2, 'join')`, [A, mem]);
  await h.fails('a member cannot read the table', `select * from voice_activity`);
  await h.fails('a member cannot insert rows', `insert into voice_activity (server_id, channel_id, user_id, kind) values ($1, $2, $3, 'join')`, [SID, A, mem]);
  await h.as(reader);
  await h.fails('a reader cannot forge rows through the writer', `select voice_activity_add($1, $2, 'leave')`, [A, mem]);
  await h.admin();
  await h.db.exec(`set role service_role`);
  const add = (cid, uid, ev, ago, sid = null) => h.q(`select voice_activity_add($1, $2, $3, now() - make_interval(secs => $4), $5)`, [cid, uid, ev, ago, sid]);
  await add(A, mem, 'join', 170);
  await add(A, mem, 'join', 169); // a retried delivery
  await add(A, mem, 'leave', 100);
  await add(A, mem, 'leave', 99); // a retried delivery
  // Leave first, then join elsewhere: one move.
  await add(A, mem, 'join', 90);
  await add(A, mem, 'leave', 30);
  await add(B, mem, 'join', 28);
  // Join first, then the old leave: one move.
  await add(C, mem, 'join', 20);
  await add(B, mem, 'leave', 19);
  await add(B, mem, 'leave', 18); // a retried delivery of the move's leave
  // A reconnect in the same channel, both orders: gone.
  await add(C, mem, 'leave', 6);
  await add(C, mem, 'join', 5);
  await add(C, mem, 'join', 4);
  await add(C, mem, 'leave', 3);
  await add(C, mem, 'leave', 0);
  // Not logged: DM call, the flag is off there, a text channel.
  await add(OFFV, mem, 'join', 0);
  await add(TEXT, mem, 'join', 0);
  await h.db.exec(`reset role`);
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', 'k670', $1) returning id`, [mem])).id;
  await h.db.exec(`set role service_role`);
  await add(dm, mem, 'join', 0);
  // Someone else. A lost leave, then a quick real visit of a new connection: kept (the sids match).
  await add(SECRET, mem2, 'join', 60);
  await add(SECRET, mem2, 'leave', 45);
  await add(B, mem2, 'join', 30, 'P1');
  await add(B, mem2, 'join', 10, 'P2');
  await add(B, mem2, 'leave', 5, 'P2');
  // Moves into and out of the hidden channel.
  await add(SECRET, mem2, 'join', 3);
  await add(SECRET, mem2, 'leave', 1);
  await add(A, mem2, 'join', 0);
  await h.db.exec(`reset role`);

  const rows = await h.q(`select kind, channel_id, from_channel, duration from voice_activity where user_id = $1 order by id`, [mem]);
  h.eq('rows for mem', rows.map((r) => [r.kind, r.channel_id, r.from_channel, r.duration]), [
    ['join', A, null, null],
    ['leave', A, null, 70],
    ['join', A, null, null],
    ['move', B, A, 60],
    ['move', C, B, 8],
    ['leave', C, null, 20],
  ]);
  h.eq('nothing outside flagged server voice', (await h.one(`select count(*)::int n from voice_activity where server_id <> $1`, [SID])).n, 0);

  // ---------- reading ----------
  await h.as(mem);
  await h.fails('a plain member cannot read the log', `select * from voice_activity_list($1)`, [SID]);
  await h.as(stranger);
  await h.fails('someone outside the server cannot read it', `select * from voice_activity_list($1)`, [SID]);
  await h.as(owner);
  await h.fails('not where the flag is off', `select * from voice_activity_list($1)`, [OFF]);
  await h.as(reader);
  const all = await h.q(`select * from voice_activity_list($1)`, [SID]);
  h.eq('reader sees the 10 visible rows, newest first', all.map((r) => r.kind), ['move', 'move', 'join', 'join', 'leave', 'move', 'move', 'join', 'leave', 'join']);
  h.eq('the hidden channel never shows', all.some((r) => r.channel_id === SECRET || r.from_channel === SECRET), false);
  h.eq('move in from the hidden channel: no from, no time', [all[0].channel_id, all[0].from_channel, all[0].duration], [A, null, null]);
  h.eq('move out to the hidden channel: no to, time in B kept', [all[1].channel_id, all[1].from_channel, all[1].duration], [null, B, 5]);
  await h.fails('asking for the hidden channel fails', `select * from voice_activity_list($1, $2)`, [SID, SECRET]);
  const inB = await h.q(`select kind from voice_activity_list($1, $2)`, [SID, B]);
  h.eq('channel filter includes moves out of it', inB.map((r) => r.kind), ['move', 'join', 'join', 'move', 'move']);
  const page = await h.q(`select id from voice_activity_list($1, null, $2, null, 2)`, [SID, mem]);
  const next = await h.q(`select id from voice_activity_list($1, null, $2, $3, 2)`, [SID, mem, page[1].id]);
  h.eq('paging', next.length === 2 && Number(next[0].id) < Number(page[1].id), true);
  await h.as(owner);
  h.eq('the owner reads it too', (await h.q(`select * from voice_activity_list($1)`, [SID])).length, 10);

  // ---------- audit: mutes and bans ----------
  await h.admin();
  const asUser = (u) => h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [u]);
  await asUser(mod);
  await h.q(`insert into server_voice_mutes (server_id, user_id, until) values ($1, $2, now() + interval '10 minutes')`, [SID, mem]);
  await h.q(`update server_voice_mutes set until = now() + interval '20 minutes' where user_id = $1`, [mem]);
  await h.q(`delete from server_voice_mutes where user_id = $1`, [mem]);
  await h.q(`insert into server_voice_bans (server_id, user_id, reason) values ($1, $2, 'yelling')`, [SID, mem]);
  await h.q(`delete from server_voice_bans where user_id = $1`, [mem]);
  // Not logged where the flag is off.
  await h.q(`insert into server_voice_mutes (server_id, user_id, until) values ($1, $2, now() + interval '10 minutes')`, [OFF, mem]);
  await h.admin();
  // No signed-in user (a cleanup job): not logged.
  await h.q(`delete from server_voice_mutes`);
  const acts = await h.q(`select act, actor, tid, extra from t670_audit order by ctid`);
  h.eq('audit rows', acts.map((a) => a.act), ['voice_mute', 'voice_mute', 'voice_unmute', 'voice_ban', 'voice_unban']);
  h.eq('actor is the mod', acts.every((a) => a.actor === mod && a.tid === mem), true);
  h.eq('ban reason kept', acts[3].extra.reason, 'yelling');

  // ---------- voice_mod_log ----------
  await h.q(`delete from t670_audit`);
  await h.as(mem);
  await h.fails('a member without Move Members cannot log a disconnect', `select voice_mod_log($1, $2, 'disconnect')`, [A, mem2]);
  await h.as(reader);
  await h.fails('View Audit Log alone cannot log a move', `select voice_mod_log($1, $2, 'move', $3)`, [A, mem, B]);
  await h.as(mod);
  await h.fails('not yourself', `select voice_mod_log($1, $2, 'disconnect')`, [A, mod]);
  await h.fails('not someone you do not outrank', `select voice_mod_log($1, $2, 'disconnect')`, [A, mem2]);
  await h.fails('not someone outside the server', `select voice_mod_log($1, $2, 'disconnect')`, [A, stranger]);
  await h.fails('not to a channel in another server', `select voice_mod_log($1, $2, 'move', $3)`, [A, mem, OFFV]);
  await h.fails('not to a text channel', `select voice_mod_log($1, $2, 'move', $3)`, [A, mem, TEXT]);
  await h.fails('not to the same channel', `select voice_mod_log($1, $2, 'move', $3)`, [A, mem, A]);
  await h.fails('not from a channel you cannot see', `select voice_mod_log($1, $2, 'disconnect')`, [SECRET, mem]);
  await h.fails('not into a channel you cannot see', `select voice_mod_log($1, $2, 'move', $3)`, [A, mem, SECRET]);
  await h.fails('not a made-up action', `select voice_mod_log($1, $2, 'ban')`, [A, mem]);
  await h.fails('not disconnecting the owner', `select voice_mod_log($1, $2, 'disconnect')`, [A, owner]);
  await h.ok('disconnect', () => h.q(`select voice_mod_log($1, $2, 'disconnect')`, [A, mem]));
  await h.ok('move', () => h.q(`select voice_mod_log($1, $2, 'move', $3)`, [A, mem, B]));
  await h.ok('moving the owner is fine with Move Members', () => h.q(`select voice_mod_log($1, $2, 'move', $3)`, [A, owner, B]));
  await h.ok('quietly nothing where the flag is off', () => h.q(`select voice_mod_log($1, $2, 'disconnect')`, [OFFV, mem]));
  await h.admin();
  await h.q(`insert into t670 (k) values ($1)`, [`staff:${mem}`]);
  await h.as(mod);
  await h.fails('not Yapin staff', `select voice_mod_log($1, $2, 'disconnect')`, [A, mem]);
  await h.admin();
  const logged = await h.q(`select act, actor, extra from t670_audit order by ctid`);
  h.eq('logged actions', logged.map((a) => a.act), ['voice_disconnect', 'voice_move', 'voice_move']);
  h.eq('move names both channels', [logged[1].extra.from, logged[1].extra.to], ['A', 'B']);
  h.eq('actor is the mod', logged.every((a) => a.actor === mod), true);
  await h.as(mem);
  await h.fails('nobody signed in can run the purge', `select voice_activity_cleanup()`);
  await h.admin();
  await h.q(`update voice_activity set at = now() - interval '15 days' where user_id = $1`, [mem2]);
  await h.q(`select voice_activity_cleanup()`);
  h.eq('purge after 14 days', (await h.one(`select count(*)::int n from voice_activity where user_id = $1`, [mem2])).n, 0);
}
