// 538: Creator Program v3: one payout per video (video_key), staff set format + views, 1k followers to apply,
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
  for (const m of ['417_creator_program.sql', '418_creator_center.sql', '419_elite_500k.sql', '497_creator_center_v2.sql', '518_creator_v3.sql', '532_creator_rewards_tune.sql', '533_creator_invites_shards_only.sql']) await h.db.exec(mig(m));
  await h.db.exec(mig('538_creator_invite_analytics.sql'));
  await h.ok('538 re-runs cleanly', () => h.db.exec(mig('538_creator_invite_analytics.sql')));
  await h.db.exec(mig('539_creator_hits_hardening.sql'));
  await h.ok('539 re-runs cleanly', () => h.db.exec(mig('539_creator_hits_hardening.sql')));
  const user = await h.signup('u@test.dev', 'creator');
  const other = await h.signup('o@test.dev', 'other');
  const fan = await h.signup('fan@test.dev', 'fan');
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'creator_program'`);
  await h.q(`update profiles set verified_as = 'YouTube · creator', badges = '{creator_1}' where id = $1`, [user]);
  await h.q(`select creator_link_code($1)`, [user]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];

  h.eq('anon can record a click', await call(null, `select creator_link_hit('creator')`), 'ok');
  h.eq('case and spaces folded', await call(null, `select creator_link_hit(' CREATOR ')`), 'ok');
  h.eq('unknown code: nothing stored', [await call(null, `select creator_link_hit('nobody')`), Number(await one(`select count(*) from creator_link_hits where code = 'nobody'`))], ['ok', 0]);
  h.eq('two clicks today', Number(await one(`select n from creator_link_hits where code = 'creator' and day = current_date`)), 2);
  h.eq('members can not read the hits table', String(await call(user, `select count(*) from creator_link_hits`)).includes('permission denied'), true);
  await h.q(`select record_creator_referral('creator', $1)`, [fan]);
  await h.q(`insert into creator_link_hits (code, day, n) values ('creator', current_date - 20, 7)`);
  const a = await call(user, `select creator_invite_analytics()`);
  h.eq('totals: clicks 9 (2 today + 7 old), 2 this week, no refused figure', [a.clicks, a.clicks_7d, a.signups, a.signups_7d, a.counted, a.waiting, 'refused' in a], [9, 2, 1, 1, 0, 1, false]);
  h.eq('14-day series, today last with 2 clicks and 1 sign-up', [a.days.length, a.days[13].clicks, a.days[13].signups, a.days[0].clicks], [14, 2, 1, 0]);
  h.eq('non-creators get null', await call(other, `select creator_invite_analytics()`), 'ok');
  h.eq('anon can not read analytics', String(await call(null, `select creator_invite_analytics()`)).includes('permission denied'), true);
}
