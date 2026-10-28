// 468: Shard quests and the Plus boost. Builds on 345 + 360 + 389 + 462 with 462's stand-ins (copied from its
// test, which dev knows as stage462b).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage345.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const MORE = `
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language sql as $$ select $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$ select public.is_site_admin() or public.is_site_mod() $$;
alter table auth.users add column if not exists email_confirmed_at timestamptz;
-- Live profiles are updatable column by column (085); the base here grants the whole table.
revoke update on public.profiles from anon, authenticated;
grant update (avatar_deco, profile_effect) on public.profiles to authenticated;
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (bot text, user_id uuid primary key);
-- join_server as it is live (pg_get_functiondef, Oct 24), with stand-ins for what it calls.
create or replace function public.server_locked(sid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.new_account_join_check(sid uuid) returns void language sql as $$ select $$;
CREATE OR REPLACE FUNCTION public.join_server(invite_code text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid; staff boolean := public.is_staff();
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select server_id into sid from public.invites where lower(code) = lower(invite_code);
  if sid is null then raise exception 'This invite is invalid or has expired'; end if;
  if not staff and public.server_locked(sid) then raise exception 'This server is locked right now. Try again in a few minutes.'; end if;
  if not staff and exists (select 1 from public.server_bans where server_id = sid and user_id = auth.uid()) then
    raise exception 'You''re banned from this server';
  end if;
  if not staff and (select count(*) from public.server_members where user_id = auth.uid()) >= 100 then
    raise exception 'You''re in too many servers';
  end if;
  -- 193: new account rule (join mode)
  if not staff then perform public.new_account_join_check(sid); end if;
  insert into public.server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  if found then
    update public.invites set uses = uses + 1 where lower(code) = lower(invite_code);
  end if;
  return sid;
end; $function$;
create table if not exists public.user_devices (user_id uuid not null, kind text not null, h text not null, first_seen timestamptz default now(), last_seen timestamptz default now(), primary key (user_id, kind, h));
`;

const MORE468 = `
alter table public.profiles add column if not exists plus_until timestamptz;
create table if not exists public.steam_links (user_id uuid primary key, steam_id text);
create table if not exists public.media_links (user_id uuid, source text, primary key (user_id, source));
create table if not exists auth.mfa_factors (id uuid primary key default gen_random_uuid(), user_id uuid, status text);
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(MORE468);
  for (const f of ['345_community_decos.sql', '360_artist_badge.sql', '389_one_decoration.sql', '462_shards.sql']) await h.db.exec(mig(f));
  const MIG = mig('468_shard_quests.sql');
  await h.ok('468 runs', () => h.db.exec(MIG));
  await h.ok('468 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag shard_quests in test', (await h.one(`select mode from feature_flags where key = 'shard_quests'`)).mode, 'test');

  const u = {};
  for (const n of ['plain', 'plus', 'fresh', 'robot', 'pal', 'nope']) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days' where id <> $1`, [u.fresh]);
  await h.q(`update profiles set plus_until = now() + interval '30 days' where id = $1`, [u.plus]);
  await h.q(`insert into bots values ($1)`, [u.robot]);
  await h.q(`update feature_flags set users = $1 where key in ('shards', 'shard_quests')`, [Object.values(u).filter((x) => x !== u.nope)]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'shards'`);

  const sid = (await h.one(`insert into servers (name, owner_id) values ('Hub', $1) returning id`, [u.pal])).id;
  const chans = [];
  for (let i = 0; i < 3; i++) chans.push((await h.one(`insert into channels (kind, name, server_id, created_by, position) values ('text', $1, $2, $3, $4) returning id`, [`c${i}`, sid, u.pal, i])).id);
  // A messages trigger stamps created_at with now(), so triggers are off while the test backdates them.
  const backdated = async (sql, params) => {
    await h.admin();
    await h.db.exec(`set session_replication_role = replica`);
    try { return await h.q(sql, params); } finally { await h.db.exec(`set session_replication_role = origin`); }
  };
  const say = (who, chan, minute, reply = null) => backdated(`insert into messages (channel_id, author_id, content, created_at, reply_to_id)
    values ($1, $2, 'hi', date_trunc('day', now() at time zone 'utc') at time zone 'utc' + make_interval(mins => $3), $4) returning id`, [chan, who, minute, reply]);
  const tick = async (who) => {
    await h.admin(); await h.q(`update shard_wallets set last_tick = null where user_id = $1`, [who]);
    await h.as(who); return (await h.one(`select shards_tick() r`)).r;
  };
  const quests = async (who) => { await h.as(who); return Object.fromEntries((await h.one(`select shard_quests() r`)).r.map((q) => [q.key, q])); };
  const claim = async (who, key) => { await h.as(who); return (await h.one(`select claim_shard_quest($1) r`, [key])).r; };

  // ---------- the boost ----------
  for (const who of [u.plain, u.plus]) for (let m = 0; m < 10; m++) await say(who, chans[0], m);
  h.eq('plain: 5 daily + 10 chatting', (await tick(u.plain)).balance, 15);
  h.eq('plus: 1.5x (8 daily + 15 chatting)', (await tick(u.plus)).balance, 23);
  h.eq('my_shards says the boost', Number((await tick(u.plus)).boost), 1.5);
  for (let m = 10; m < 60; m++) await say(u.plus, chans[0], m);
  h.eq('plus chatting cap is 25 base (38 paid): 8 + 15 + 23', (await tick(u.plus)).balance, 46);
  await h.admin();
  await h.q(`update feature_flags set users = array_remove(users, $1::uuid) where key = 'shard_quests'`, [u.plus]);
  await h.as(u.plus);
  h.eq('no flag: no boost', Number((await h.one(`select my_shards()->>'boost' b`)).b), 1);
  await h.admin();
  await h.q(`update feature_flags set users = array_append(users, $1::uuid) where key = 'shard_quests'`, [u.plus]);

  // ---------- quests ----------
  let q = await quests(u.plain);
  h.eq('9 quests', Object.keys(q).length, 9);
  h.eq('chats3 not done with one chat', q.chats3.done, false);
  await h.as(u.plain);
  await h.fails('claiming an unfinished quest fails', `select claim_shard_quest('chats3')`);
  await h.fails('unknown quest fails', `select claim_shard_quest('free_money')`);
  await say(u.plain, chans[1], 100);
  const m3 = (await say(u.plain, chans[2], 101))[0].id;
  q = await quests(u.plain);
  h.eq('chats3 done with 3 chats', [q.chats3.done, q.chats3.claimed, q.chats3.reward], [true, false, 10]);
  h.eq('claim chats3: +10', (await claim(u.plain, 'chats3')).balance, 25);
  await h.as(u.plain);
  h.eq('claiming twice says so', await h.q(`select claim_shard_quest('chats3')`).then(() => 'paid', (e) => e.message), 'Already claimed');
  h.eq('shows claimed', (await quests(u.plain)).chats3.claimed, true);

  // reply + reactions: only on other people's messages.
  await say(u.plain, chans[0], 102, m3);
  h.eq('replying to yourself does not count', (await quests(u.plain)).reply.done, false);
  await h.admin();
  const theirs = (await h.one(`select id from messages where author_id = $1 limit 1`, [u.plus])).id;
  await say(u.plain, chans[0], 103, theirs);
  h.eq('reply to someone else done', (await quests(u.plain)).reply.done, true);
  await h.admin();
  const mine = await h.q(`select id from messages where author_id = $1 limit 3`, [u.plain]);
  for (const m of mine) await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, 'ok')`, [m.id, u.plain]);
  h.eq('reacting to yourself does not count', (await quests(u.plain)).react3.done, false);
  await h.admin();
  const msgs = await h.q(`select id from messages where author_id = $1 limit 3`, [u.plus]);
  for (const m of msgs) await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, 'ok')`, [m.id, u.plain]);
  h.eq('react3 done on other people', (await quests(u.plain)).react3.done, true);

  // once: profile, friend, servers3, deco, connect, mfa
  const ONCE = ['profile', 'friend', 'servers3', 'deco', 'connect', 'mfa'];
  q = await quests(u.plain);
  h.eq('once quests start undone', ONCE.map((k) => q[k].done), [false, false, false, false, false, false]);
  await h.admin();
  await h.q(`update profiles set avatar_path = id::text || '/a.png', bio = 'hi there' where id = $1`, [u.plain]);
  await h.q(`insert into friendships (requester, addressee, status) values ($1, $2, 'accepted')`, [u.pal, u.plain]);
  for (let i = 0; i < 3; i++) {
    const s = (await h.one(`insert into servers (name, owner_id) values ($1, $2) returning id`, [`S${i}`, u.pal])).id;
    await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [s, u.plain]);
  }
  await h.q(`update profiles set avatar_deco = 'crown' where id = $1`, [u.plain]);
  await h.q(`insert into media_links (user_id, source) values ($1, 'anilist')`, [u.plain]);
  await h.q(`insert into auth.mfa_factors (user_id, status) values ($1, 'unverified')`, [u.plain]);
  q = await quests(u.plain);
  h.eq('once quests done (unverified 2FA does not count)', ONCE.map((k) => q[k].done), [true, true, true, true, true, false]);
  h.eq('profile pays 25', (await claim(u.plain, 'profile')).balance, 50);
  h.eq('mfa refused while unverified', await claim(u.plain, 'mfa').then(() => 'paid', () => 'refused'), 'refused');
  await h.admin();
  await h.q(`update auth.mfa_factors set status = 'verified' where user_id = $1`, [u.plain]);
  h.eq('mfa pays 50 once verified', (await claim(u.plain, 'mfa')).balance, 100);

  // Plus gets 1.5x on quests too.
  await h.admin();
  await h.q(`update profiles set avatar_path = id::text || '/a.png', bio = 'plus' where id = $1`, [u.plus]);
  h.eq('plus sees the boosted reward', (await quests(u.plus)).profile.reward, 38);
  h.eq('plus profile pays 38', (await claim(u.plus, 'profile')).balance, 46 + 38);

  // Who can't.
  await h.admin();
  await h.q(`update profiles set avatar_path = id::text || '/a.png', bio = 'x' where id = any($1::uuid[])`, [[u.fresh, u.robot, u.nope, u.pal]]);
  await h.as(u.fresh);
  await h.fails('account under 3 days can not claim', `select claim_shard_quest('profile')`);
  await h.as(u.robot);
  await h.fails('bots can not claim', `select claim_shard_quest('profile')`);
  await h.as(u.nope);
  await h.fails('no flag: can not claim', `select claim_shard_quest('profile')`);
  h.eq('no flag: empty list', (await h.one(`select shard_quests() r`)).r, []);
  await h.admin();
  await h.q(`update feature_flags set mode = 'test', users = array[$1]::uuid[] where key = 'shards'`, [u.pal]);
  await h.as(u.plain);
  h.eq('no shards flag: no quests either', (await h.one(`select shard_quests() r`)).r, []);
  await h.fails('no shards flag: can not claim', `select claim_shard_quest('reply')`);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'shards'`);
  await h.admin();
  await h.q(`insert into shard_wallets (user_id, frozen) values ($1, true) on conflict (user_id) do update set frozen = true`, [u.pal]);
  await h.as(u.pal);
  await h.fails('frozen can not claim', `select claim_shard_quest('profile')`);

  // Nobody calls the helpers.
  await h.as(u.plain);
  await h.fails('no shard_earn from clients', `select shard_earn($1, 1000, 'quest', 'x')`, [u.plain]);
  await h.fails('no shard_boost from clients', `select shard_boost($1)`, [u.plain]);
  await h.fails('no shard_quest_met from clients', `select shard_quest_met($1, 'mfa')`, [u.plain]);
  await h.admin();
  h.eq('every balance matches its ledger', (await h.one(`select count(*)::int n from shard_wallets w where balance <> coalesce((select sum(amount) from shard_ledger l where l.user_id = w.user_id), 0)`)).n, 0);
}
