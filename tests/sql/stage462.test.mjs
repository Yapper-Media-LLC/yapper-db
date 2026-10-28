// 462: Shards. Earning from activity (daily, active minutes with a cap, 7-day streak) and from invites (referral
// noted in join_server, paid once the friend is real), spending on community decorations (80% to the artist) and
// account levels, staff tools, and that nobody can write the ledger or wallets directly.
// Builds on 345 + 360 + 389 with the same stand-ins.
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

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(mig('345_community_decos.sql'));
  await h.db.exec(mig('360_artist_badge.sql'));
  await h.db.exec(mig('389_one_decoration.sql'));
  const MIG = mig('462_shards.sql');
  await h.ok('462 runs', () => h.db.exec(MIG));
  await h.ok('462 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag shards in test', (await h.one(`select mode from feature_flags where key = 'shards'`)).mode, 'test');

  const names = ['me', 'fresh', 'robot', 'outlaw', 'artist', 'buyer', 'kid', 'twin', 'inviter', 'newbie', 'newbie2', 'oldie', 'staff', 'boss', 'streaky'];
  const u = {};
  for (const n of names) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  // Most accounts are old enough; fresh and kid are not.
  await h.q(`update profiles set created_at = now() - interval '30 days' where id <> all($1::uuid[])`, [[u.fresh, u.kid, u.newbie, u.newbie2]]);
  await h.q(`update profiles set created_at = now() - interval '2 days' where id = $1`, [u.kid]);
  await h.q(`insert into site_moderators values ($1)`, [u.staff]);
  await h.q(`insert into site_admins values ($1)`, [u.boss]);
  await h.q(`insert into bots values ($1)`, [u.robot]);

  const sid = (await h.one(`insert into servers (name, owner_id) values ('Hub', $1) returning id`, [u.inviter])).id;
  const chan = (await h.one(`insert into channels (kind, name, server_id, created_by, position) values ('text', 'general', $1, $2, 0) returning id`, [sid, u.inviter])).id;
  // n messages in n different minutes of today (UTC). A messages trigger stamps created_at with now(), so the
  // triggers are off while the test backdates them.
  const backdated = async (sql, params) => {
    await h.admin();
    await h.db.exec(`set session_replication_role = replica`);
    try { await h.q(sql, params); } finally { await h.db.exec(`set session_replication_role = origin`); }
  };
  const talk = (who, minutes, from = 0) => backdated(`insert into messages (channel_id, author_id, content, created_at)
      select $1, $2, 'hi', date_trunc('day', now() at time zone 'utc') at time zone 'utc' + make_interval(mins => g)
      from generate_series($3::int, $3::int + $4::int - 1) g`, [chan, who, from, minutes]);
  // The server ticks once a minute per person at most; the test clears that between ticks.
  const tick = async (who, fast = true) => {
    if (fast) { await h.admin(); await h.q(`update shard_wallets set last_tick = null where user_id = $1`, [who]); }
    await h.as(who);
    return (await h.one(`select shards_tick() r`)).r;
  };
  const bal = async (who) => { await h.admin(); return (await h.one(`select coalesce((select balance from shard_wallets where user_id = $1), 0) b`, [who])).b; };

  // ---------- flag ----------
  await talk(u.me, 1);
  await h.as(u.me);
  await h.fails('no flag: no tick', `select shards_tick()`);
  await h.admin();
  await h.q(`update feature_flags set users = $1 where key = 'shards'`, [Object.values(u)]);

  // ---------- activity ----------
  let r = await tick(u.me);
  h.eq('1 active minute: daily 5 only', r.balance, 5);
  h.eq('daily marked', r.today.daily, true);
  await talk(u.me, 12, 1);
  await backdated(`insert into messages (channel_id, author_id, content, created_at) select $1, $2, 'spam', date_trunc('day', now() at time zone 'utc') at time zone 'utc' + interval '3 minutes' from generate_series(1, 20)`, [chan, u.me]);
  r = await tick(u.me);
  h.eq('13 active minutes (spam in one minute counts once): 5 + 10', r.balance, 15);
  h.eq('tick says what it paid', r.gained, 10);
  r = await tick(u.me);
  h.eq('ticking again pays nothing more', r.balance, 15);
  await talk(u.me, 5, 60);
  r = await tick(u.me, false);
  h.eq('a second tick within a minute does nothing', r.balance, 15);
  await talk(u.me, 40, 13);
  r = await tick(u.me);
  h.eq('activity capped at 25 a day (5 + 25)', r.balance, 30);
  h.eq('one daily row', (await h.one(`select count(*)::int n from shard_ledger where user_id = $1 and kind = 'daily'`, [u.me])).n, 1);

  await talk(u.fresh, 10);
  h.eq('account under 3 days: nothing', (await tick(u.fresh)).balance, 0);
  await talk(u.robot, 10);
  h.eq('bot: nothing', (await tick(u.robot)).balance, 0);
  h.eq('no talk today: nothing', (await tick(u.oldie)).balance, 0);

  // streak: 6 days in a row so far, today is the 7th.
  await h.admin();
  await h.q(`insert into shard_wallets (user_id, streak, last_day) values ($1, 6, (now() at time zone 'utc')::date - 1)`, [u.streaky]);
  await talk(u.streaky, 1);
  r = await tick(u.streaky);
  h.eq('7th day in a row: 5 + 30', r.balance, 35);
  h.eq('streak is 7', r.streak, 7);

  // ---------- nobody writes directly ----------
  await h.as(u.me);
  await h.fails('no ledger insert', `insert into shard_ledger (user_id, amount, kind, balance_after) values ($1, 1000, 'daily', 1000)`, [u.me]);
  await h.fails('no wallet update', `update shard_wallets set balance = 99999 where user_id = $1`, [u.me]);
  const upd = await h.q(`update shard_wallets set balance = 99999 where user_id = $1 returning 1`, [u.me]).catch(() => []);
  h.eq('wallet unchanged', upd.length, 0);
  await h.fails('no shard_post from clients', `select shard_post($1, 1000, 'daily', 'x')`, [u.me]);
  await h.fails('no shard_referral_check from clients', `select shard_referral_check($1)`, [u.me]);
  await h.fails('no device check from clients (alts stay hidden)', `select shard_shared_device($1, $2)`, [u.me, u.fresh]);
  await h.fails('no bot check from clients', `select shard_is_bot($1)`, [u.me]);
  await h.fails('no account_level writes', `update profiles set account_level = 99 where id = $1`, [u.me]);
  h.eq('my ledger only', (await h.one(`select count(distinct user_id)::int n from shard_ledger`)).n, 1);
  await h.fails('no staff view for users', `select staff_shards($1)`, [u.streaky]);

  // ---------- invites ----------
  await h.admin();
  await h.q(`insert into invites (code, server_id, created_by) values ('hubcode', $1, $2)`, [sid, u.inviter]);
  await h.as(u.newbie);
  await h.q(`select join_server('hubcode')`);
  await h.as(u.oldie);
  await h.q(`select join_server('HubCode')`);
  await h.admin();
  h.eq('new account: referral noted', (await h.one(`select inviter, status from referrals where invitee = $1`, [u.newbie])), { inviter: u.inviter, status: 'pending' });
  h.eq('old account: no referral', (await h.one(`select count(*)::int n from referrals where invitee = $1`, [u.oldie])).n, 0);
  h.eq('invite uses still counted', (await h.one(`select uses from invites where code = 'hubcode'`)).uses, 2);

  // Not ready yet: account is new.
  await talk(u.newbie, 1);
  await tick(u.newbie);
  h.eq('friend too new: inviter not paid', await bal(u.inviter), 0);
  // Ready: 8 days old, email confirmed, active on 3 days.
  await h.q(`update profiles set created_at = now() - interval '8 days' where id = $1`, [u.newbie]);
  await h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [u.newbie]);
  await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - 3, 4), ($1, current_date - 2, 2) on conflict do nothing`, [u.newbie]);
  await tick(u.newbie); // counts today
  await tick(u.newbie); // the referral is checked at the start of a tick
  h.eq('real friend: inviter gets 100', await bal(u.inviter), 100);
  h.eq('referral paid', (await h.one(`select status from referrals where invitee = $1`, [u.newbie])).status, 'paid');
  await tick(u.newbie);
  h.eq('paid once', await bal(u.inviter), 100);

  // Same device as the inviter: refused for good.
  await h.as(u.newbie2);
  await h.q(`select join_server('hubcode')`);
  await h.admin();
  await h.q(`insert into user_devices (user_id, kind, h) values ($1, 'dev', 'abc'), ($2, 'dev', 'abc')`, [u.inviter, u.newbie2]);
  await h.q(`update profiles set created_at = now() - interval '8 days' where id = $1`, [u.newbie2]);
  await h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [u.newbie2]);
  await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - 3, 4), ($1, current_date - 2, 2)`, [u.newbie2]);
  await talk(u.newbie2, 1);
  await tick(u.newbie2);
  await h.admin();
  h.eq('same device: refused', (await h.one(`select status, reason from referrals where invitee = $1`, [u.newbie2])), { status: 'refused', reason: 'same device or network' });
  h.eq('same device: not paid', await bal(u.inviter), 100);

  // Cap: 10 paid in 30 days and the next one waits.
  const fakes = [];
  for (let i = 0; i < 9; i++) fakes.push(await h.signup(`f${i}@test.dev`, `f${i}`));
  const late = await h.signup('late@test.dev', 'late');
  await h.admin();
  for (const f of fakes) await h.q(`insert into referrals (invitee, inviter, status, paid_at) values ($1, $2, 'paid', now())`, [f, u.inviter]);
  await h.q(`insert into referrals (invitee, inviter) values ($1, $2)`, [late, u.inviter]);
  await h.q(`update profiles set created_at = now() - interval '8 days' where id = $1`, [late]);
  await h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [late]);
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'shards'`, [late]);
  await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - 3, 4), ($1, current_date - 2, 2)`, [late]);
  await talk(late, 1);
  await tick(late);
  await tick(late);
  await h.admin();
  h.eq('over the 30-day cap: waits', (await h.one(`select status from referrals where invitee = $1`, [late])).status, 'pending');
  await h.q(`update referrals set paid_at = now() - interval '31 days' where inviter = $1 and invitee <> $2`, [u.inviter, u.newbie]);
  await tick(late);
  await h.admin();
  h.eq('once older ones drop out of the 30 days: paid', (await h.one(`select status from referrals where invitee = $1`, [late])).status, 'paid');

  // ---------- levels ----------
  await h.as(u.oldie);
  await h.fails('level up without Shards', `select level_up()`);
  await h.as(u.boss);
  await h.q(`select staff_adjust_shards($1, 450, 'testing levels')`, [u.oldie]);
  await h.as(u.oldie);
  r = (await h.one(`select level_up() r`)).r;
  h.eq('level 1 costs 100', [r.level, r.balance], [1, 350]);
  await h.admin();
  await h.q(`update profiles set account_level = 10 where id = $1`, [u.oldie]);
  await h.as(u.oldie);
  r = (await h.one(`select level_up() r`)).r;
  await h.admin();
  await h.q(`update profiles set account_level = 0 where id = $1`, [u.oldie]);
  await h.as(u.oldie);
  await h.fails('climbing back to a paid level is not free', `select level_up()`);
  await h.admin();
  await h.q(`update profiles set account_level = 11 where id = $1`, [u.oldie]);
  h.eq('level 11 costs 200', [r.level, r.balance, r.next_cost], [11, 150, 200]);
  await h.fails('level 12 needs 200', `select level_up()`);
  await h.admin();
  await h.q(`update profiles set account_level = 100 where id = $1`, [u.oldie]);
  await h.as(u.oldie);
  await h.fails('no level past 100', `select level_up()`);

  // ---------- decorations ----------
  await h.admin();
  await h.q(`insert into media_ok_paths values ($1)`, [`${u.artist}/cool.png`]);
  const deco = (await h.one(`insert into community_decos (name, artist_id, path, status) values ('Cool', $1, $2, 'approved') returning id`, [u.artist, `${u.artist}/cool.png`])).id;
  const wear = async (who) => { await h.as(who); return h.q(`update profiles set avatar_deco = $2 where id = $1`, [who, `c:${u.artist}/cool.png`]); };
  await wear(u.oldie); // worn while free
  await h.as(u.buyer);
  await h.fails('not the artist: no price', `select set_deco_price($1, 100)`, [deco]);
  await h.as(u.artist);
  await h.fails('price under 25 refused', `select set_deco_price($1, 10)`, [deco]);
  await h.q(`select set_deco_price($1, 100)`, [deco]);
  h.eq('price set', (await h.one(`select price from community_decos where id = $1`, [deco])).price, 100);
  await h.admin();
  h.eq('who wore it keeps it', (await h.one(`select price_paid from deco_owned where user_id = $1 and deco_id = $2`, [u.oldie, deco])).price_paid, 0);
  await wear(u.artist);
  h.eq('artist wears their own', (await h.one(`select avatar_deco from profiles where id = $1`, [u.artist])).avatar_deco, `c:${u.artist}/cool.png`);
  await h.as(u.buyer);
  await h.fails('priced, not owned: can\'t wear', `update profiles set avatar_deco = $2 where id = $1`, [u.buyer, `c:${u.artist}/cool.png`]);
  await h.fails('not enough Shards', `select buy_community_deco($1, 100)`, [deco]);
  await h.as(u.boss);
  await h.q(`select staff_adjust_shards($1, 150, 'testing decos')`, [u.buyer]);
  await h.q(`select staff_adjust_shards($1, 500, 'testing decos')`, [u.kid]);
  await h.q(`select staff_adjust_shards($1, 500, 'testing decos')`, [u.twin]);
  await h.as(u.buyer);
  r = (await h.one(`select buy_community_deco($1, 100) r`, [deco])).r;
  h.eq('buyer pays 100', r.balance, 50);
  h.eq('artist gets 80', await bal(u.artist), 80);
  await wear(u.buyer);
  h.eq('bought: wears it', (await h.one(`select avatar_deco from profiles where id = $1`, [u.buyer])).avatar_deco, `c:${u.artist}/cool.png`);
  await h.as(u.buyer);
  await h.fails('can\'t buy twice', `select buy_community_deco($1, 100)`, [deco]);
  await h.as(u.artist);
  await h.fails('can\'t buy your own', `select buy_community_deco($1, 100)`, [deco]);
  await h.as(u.kid);
  await h.fails('account under a week can\'t buy', `select buy_community_deco($1, 100)`, [deco]);
  await h.admin();
  await h.q(`insert into user_devices (user_id, kind, h) values ($1, 'ip', 'zzz'), ($2, 'ip', 'zzz')`, [u.artist, u.twin]);
  await h.as(u.twin);
  await h.fails('same network as the artist can\'t buy', `select buy_community_deco($1, 100)`, [deco]);
  h.eq('failed buys cost nothing', await bal(u.twin), 500);

  // ---------- bans and freezes ----------
  await talk(u.outlaw, 10);
  await h.admin();
  await h.q(`insert into banned values ($1)`, [u.outlaw]);
  h.eq('banned: earns nothing', (await tick(u.outlaw)).balance, 0);
  h.eq('banned: shows frozen', (await tick(u.outlaw)).frozen, true);
  await h.as(u.staff);
  await h.fails('mods can\'t freeze', `select staff_freeze_shards($1, true, 'abuse')`, [u.me]);
  await h.as(u.boss);
  await h.q(`select staff_freeze_shards($1, true, 'farming')`, [u.buyer]);
  await h.as(u.buyer);
  await h.fails('frozen: can\'t level up', `select level_up()`);
  await h.as(u.boss);
  await h.q(`select staff_freeze_shards($1, false, 'sorted')`, [u.buyer]);

  // A frozen friend doesn't pay their inviter.
  const alt = await h.signup('alt@test.dev', 'alt');
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'shards'`, [alt]);
  await h.q(`insert into referrals (invitee, inviter) values ($1, $2)`, [alt, u.oldie]);
  await h.q(`update profiles set created_at = now() - interval '8 days' where id = $1`, [alt]);
  await h.q(`update auth.users set email_confirmed_at = now() where id = $1`, [alt]);
  await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - 3, 4), ($1, current_date - 2, 2), ($1, current_date - 1, 2)`, [alt]);
  await h.q(`insert into shard_wallets (user_id, frozen) values ($1, true)`, [alt]);
  await talk(alt, 1);
  await tick(alt);
  await h.admin();
  h.eq('frozen friend: inviter not paid', (await h.one(`select status from referrals where invitee = $1`, [alt])).status, 'pending');

  // ---------- staff ----------
  await h.as(u.staff);
  await h.fails('mods can\'t adjust', `select staff_adjust_shards($1, 100, 'gift')`, [u.me]);
  const view = (await h.one(`select staff_shards($1) r`, [u.inviter])).r;
  h.eq('staff see referrals', view.referrals.length, 12);
  h.eq('staff see the ledger', view.ledger[0].kind, 'invite');
  await h.as(u.boss);
  await h.fails('adjust needs a reason', `select staff_adjust_shards($1, 10, '')`, [u.me]);
  await h.fails('not your own', `select staff_adjust_shards($1, 10, 'me me me')`, [u.boss]);
  h.eq('taking more than they have takes all', (await h.one(`select staff_adjust_shards($1, -1000, 'clawback') b`, [u.me])).b, 0);
  await h.admin();
  h.eq('adjustments logged', (await h.one(`select count(*)::int n from mod_log where action = 'shards_adjust'`)).n, 5);
  h.eq('freezes logged', (await h.one(`select count(*)::int n from mod_log where action in ('shards_freeze', 'shards_unfreeze')`)).n, 2);
  await h.as(u.boss);
  h.eq('every balance matches its ledger', (await h.q(`select * from shards_audit()`)).length, 0);
  await h.admin();
  h.eq('balance_after chains', (await h.one(`select bool_and(ok) ok from (select balance_after = sum(amount) over (partition by user_id order by id) ok from shard_ledger) x`)).ok, true);
}
