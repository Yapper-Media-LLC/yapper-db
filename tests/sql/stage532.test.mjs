// 532: Creator Program v3: one payout per video (video_key), staff set format + views, 1k followers to apply,
// stable invite codes, invites count only real accounts (7 days, active on 3, not on the creator's device).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

const STANDINS = `
create table if not exists public.t532_shards (user_id uuid, amount int, kind text, ref text, note text);
create or replace function public.shard_post(p_user uuid, p_amount int, p_kind text, p_ref text, p_note text default '', p_actor uuid default null, p_staff boolean default false) returns int language plpgsql as $$
begin
  if exists (select 1 from public.shard_wallets where user_id = p_user and frozen) then raise exception 'Your Shards are frozen'; end if;
  insert into public.t532_shards values (p_user, p_amount, p_kind, p_ref, p_note); return p_amount;
end $$;
alter table auth.users add column if not exists email_confirmed_at timestamptz default now();
create table if not exists public.t417_admins (id uuid primary key);
create table if not exists public.t417_banned (id uuid primary key);
create table if not exists public.t518_shared (a uuid, b uuid);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
alter table public.profiles add column if not exists verified_as text;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists verify_required boolean not null default false;
alter table public.profiles add column if not exists created_at timestamptz not null default now();
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text, servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.shard_days (user_id uuid, day date, minutes int not null default 0, primary key (user_id, day));
create table if not exists public.shard_wallets (user_id uuid primary key, frozen boolean not null default false);
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select exists (select 1 from public.t417_admins where id = auth.uid()) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.t417_banned where id = uid) $$;
create or replace function public.feature_on_for_me(k text) returns boolean language sql stable as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and auth.uid() = any(users)) from public.feature_flags where key = k), false) $$;
create or replace function public.rt_profile_changed(uids uuid[]) returns void language sql as $$ select $$;
create or replace function public.shard_is_bot(uid uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.profiles where id = uid and 'bot' = any(badges)) $$;
create or replace function public.shard_shared_device(a uuid, b uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.t518_shared s where (s.a = $1 and s.b = $2) or (s.a = $2 and s.b = $1)) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  for (const m of ['417_creator_program.sql', '418_creator_center.sql', '419_elite_500k.sql', '497_creator_center_v2.sql', '518_creator_v3.sql']) await h.db.exec(mig(m));
  await h.db.exec(mig('532_creator_rewards_tune.sql'));
  await h.ok('532 re-runs cleanly', () => h.db.exec(mig('532_creator_rewards_tune.sql')));
  await h.db.exec(mig('533_creator_invites_shards_only.sql'));
  await h.ok('533 re-runs cleanly', () => h.db.exec(mig('533_creator_invites_shards_only.sql')));
  const admin = await h.signup('admin@test.dev', 'admin');
  const a1 = await h.signup('a1@test.dev', 'plain');
  const a2 = await h.signup('a2@test.dev', 'pro');
  const a3 = await h.signup('a3@test.dev', 'elite');
  await h.admin();
  await h.q(`insert into t417_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'creator_program'`);
  await h.q(`update profiles set verified_as = 'YouTube · x' where id in ($1, $2, $3)`, [a1, a2, a3]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];
  const daysLeft = (until) => until === null ? null : Math.round((new Date(until) - Date.now()) / 864e5);

  // Content ladder: 1 / 2 / 4 / 8
  h.eq('long 5k: 1', await one(`select creator_reward_months('long', 5000)`), 1);
  h.eq('long 25k: 2', await one(`select creator_reward_months('long', 25000)`), 2);
  h.eq('long 100k: 4', await one(`select creator_reward_months('long', 100000)`), 4);
  h.eq('long 500k: 8', await one(`select creator_reward_months('long', 500000)`), 8);
  h.eq('long 4,999: 0', await one(`select creator_reward_months('long', 4999)`), 0);
  h.eq('short 2.5M: 8', await one(`select creator_reward_months('short', 2500000)`), 8);

  // Joining: Creator 0, Pro 3, Elite 6
  const apps = {};
  for (const [who, name] of [[a1, 'plain'], [a2, 'pro'], [a3, 'elite']]) {
    apps[name] = await call(who, `select apply_creator(2000, 'https://youtube.com/@' || $1, '')`, [name]);
  }
  h.eq('three applications', Object.values(apps).every((v) => typeof v === 'string' && v.length === 36), true);
  h.eq('approve as Creator', await call(admin, `select review_creator($1, true, 1, '')`, [apps.plain]), 'ok');
  h.eq('Creator: badge, no Plus, no plus_gift row', [await one(`select badges from profiles where id = $1`, [a1]), await one(`select plus_until from profiles where id = $1`, [a1]), Number(await one(`select count(*) from mod_log where target_id = $1 and action = 'plus_gift'`, [a1]))], [['creator_1'], null, 0]);
  h.eq('approve as Pro', await call(admin, `select review_creator($1, true, 2, '')`, [apps.pro]), 'ok');
  h.eq('Pro: badge + 3 months', [await one(`select badges from profiles where id = $1`, [a2]), daysLeft(await one(`select plus_until from profiles where id = $1`, [a2]))], [['creator_2'], 93]);
  h.eq('Pro: plus_months 3 on the application', await one(`select plus_months from creator_applications where id = $1`, [apps.pro]), 3);
  h.eq('Pro: plus_gift logged', Number(await one(`select count(*) from mod_log where target_id = $1 and action = 'plus_gift'`, [a2])), 1);
  await h.q(`update profiles set plus_until = now() + interval '10 days' where id = $1`, [a3]);
  h.eq('approve as Elite', await call(admin, `select review_creator($1, true, 3, 'big')`, [apps.elite]), 'ok');
  h.eq('Elite: badge + 6 months on top of existing Plus', [await one(`select badges from profiles where id = $1`, [a3]), daysLeft(await one(`select plus_until from profiles where id = $1`, [a3]))], [['creator_3'], 196]);
  h.eq('Elite: invite code made', typeof (await one(`select code from creator_links where user_id = $1`, [a3])) === 'string', true);
  h.eq('already reviewed', await call(admin, `select review_creator($1, true, 2, '')`, [apps.pro]), 'Already reviewed');

  // Shards for counted invites: 50 per real person, once; a frozen creator wallet doesn't stop the count
  const fan = await h.signup('fan@test.dev', 'fan');
  const fan2 = await h.signup('fan2@test.dev', 'fan2');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '8 days' where id in ($1, $2)`, [fan, fan2]);
  for (const f of [fan, fan2]) {
    await h.q(`select record_creator_referral('pro', $1)`, [f]);
    await h.q(`update creator_referrals set created_at = now() - interval '8 days' where user_id = $1`, [f]);
    for (let d = 0; d < 3; d++) await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - $2::int, 5) on conflict (user_id, day) do update set minutes = 5`, [f, d]);
  }
  h.eq('first real invite counted', await one(`select creator_referral_check($1)`, [fan]), 'counted');
  h.eq('10 Shards to the creator, kind invite, ref = the new account', (await h.q(`select amount, kind, ref from t532_shards where user_id = $1`, [a2])), [{ amount: 10, kind: 'invite', ref: `creator:${fan}` }]);
  h.eq('checking again pays nothing more', [await one(`select creator_referral_check($1)`, [fan]), Number(await one(`select count(*) from t532_shards where user_id = $1`, [a2]))], [null, 1]);
  await h.q(`insert into shard_wallets (user_id, frozen) values ($1, true) on conflict (user_id) do update set frozen = true`, [a2]);
  h.eq('frozen creator: still counted, no Shards', [await one(`select creator_referral_check($1)`, [fan2]), Number(await one(`select count(*) from t532_shards where user_id = $1`, [a2])), await one(`select counted from creator_links where user_id = $1`, [a2])], ['counted', 1, 2]);
  // No Plus step any more: the 25th counted invite pays Shards like any other
  await h.q(`update shard_wallets set frozen = false where user_id = $1`, [a2]);
  await h.q(`update creator_links set counted = 24 where user_id = $1`, [a2]);
  const fan3 = await h.signup('fan3@test.dev', 'fan3');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '8 days' where id = $1`, [fan3]);
  await h.q(`select record_creator_referral('pro', $1)`, [fan3]);
  await h.q(`update creator_referrals set created_at = now() - interval '8 days' where user_id = $1`, [fan3]);
  for (let d = 0; d < 3; d++) await h.q(`insert into shard_days (user_id, day, minutes) values ($1, current_date - $2::int, 5) on conflict (user_id, day) do update set minutes = 5`, [fan3, d]);
  const plus25 = await one(`select plus_until from profiles where id = $1`, [a2]);
  h.eq('25th invite: counted', await one(`select creator_referral_check($1)`, [fan3]), 'counted');
  h.eq('25th invite: 10 Shards, Plus unchanged, no plus_gift for invites', [Number(await one(`select count(*) from t532_shards where user_id = $1 and ref = $2`, [a2, `creator:${fan3}`])), String(await one(`select plus_until from profiles where id = $1`, [a2])) === String(plus25), Number(await one(`select count(*) from mod_log where target_id = $1 and action = 'plus_gift' and reason like '%sign-ups%'`, [a2]))], [1, true, 0]);
}
