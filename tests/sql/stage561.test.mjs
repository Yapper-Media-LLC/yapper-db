// 561: Creator Program v3: one payout per video (video_key), staff set format + views, 1k followers to apply,
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
  await h.db.exec(mig('561_creator_content_check_later.sql'));
  await h.ok('561 re-runs cleanly', () => h.db.exec(mig('561_creator_content_check_later.sql')));
  const admin = await h.signup('admin@test.dev', 'admin');
  const user = await h.signup('u@test.dev', 'creator');
  await h.admin();
  await h.q(`insert into t417_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'creator_program'`);
  await h.q(`update profiles set verified_as = 'YouTube · creator', badges = '{creator_1}' where id = $1`, [user]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];
  const ids = ['dQw4w9WgXcQ', 'AbCdEfGhIjK', 'ZyXwVuTsRqP', 'QqQqQqQqQqQ'];
  const c = [];
  for (const id of ids.slice(0, 3)) c.push(await call(user, `select submit_creator_content('https://youtube.com/watch?v=' || $1, '', 200)`, [id]));
  h.eq('three sent in', c.every((x) => typeof x === 'string' && x.length === 36), true);
  h.eq('a fourth is refused (3 waiting)', await call(user, `select submit_creator_content('https://youtube.com/watch?v=' || $1, '', 200)`, [ids[3]]), 'You have 3 waiting for review already. Wait for those first.');
  h.eq('members can not park', String(await call(user, `select snooze_creator_content($1, 7)`, [c[0]])).includes('Admins only'), true);
  h.eq('0 days refused', await call(admin, `select snooze_creator_content($1, 0)`, [c[0]]), 'Between 1 and 60 days');
  const until = await call(admin, `select snooze_creator_content($1, 7)`, [c[0]]);
  h.eq('parked for 7 days', Math.round((new Date(until) - Date.now()) / 864e5), 7);
  h.eq('still pending, logged', [(await h.q(`select status from creator_content where id = $1`, [c[0]]))[0].status, Number(await one(`select count(*) from mod_log where target_id = $1 and action = 'content_later'`, [user]))], ['pending', 1]);
  h.eq('a parked piece frees a slot', typeof (await call(user, `select submit_creator_content('https://youtube.com/watch?v=' || $1, '', 200)`, [ids[3]])) === 'string', true);
  h.eq('approve a parked piece later works', await call(admin, `select review_creator_content($1, true, '', 9000)`, [c[0]]), 'ok');
  h.eq('can not park a reviewed piece', await call(admin, `select snooze_creator_content($1, 3)`, [c[0]]), 'Already reviewed');
}
