// 543: Creator Program v3: one payout per video (video_key), staff set format + views, 1k followers to apply,
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
  for (const m of ['417_creator_program.sql', '418_creator_center.sql', '419_elite_500k.sql', '497_creator_center_v2.sql', '518_creator_v3.sql', '532_creator_rewards_tune.sql', '533_creator_invites_shards_only.sql', '538_creator_invite_analytics.sql', '539_creator_hits_hardening.sql']) await h.db.exec(mig(m));
  await h.db.exec(mig('543_creator_screening.sql'));
  await h.ok('543 re-runs cleanly', () => h.db.exec(mig('543_creator_screening.sql')));
  await h.db.exec(mig('567_creator_apply_no_videos.sql'));
  await h.ok('567 re-runs cleanly', () => h.db.exec(mig('567_creator_apply_no_videos.sql')));
  const admin = await h.signup('admin@test.dev', 'admin');
  const a = await h.signup('a@test.dev', 'yt');
  const b = await h.signup('b@test.dev', 'ig');
  const c = await h.signup('c@test.dev', 'quiet');
  const d = await h.signup('d@test.dev', 'active');
  await h.admin();
  await h.q(`insert into t417_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'creator_program'`);
  await h.q(`update profiles set verified_as = 'YouTube · x' where id in ($1, $2, $3, $4)`, [a, b, c, d]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];

  h.eq('one apply_creator', Number(await one(`select count(*) from pg_proc where proname = 'apply_creator'`)), 1);
  const okChk = JSON.stringify({ platform: 'youtube', checked: true, ok: true, reasons: [], subscribers: 5400, lastPost: new Date().toISOString(), posts90d: 4, source: 'api' });
  const badChk = JSON.stringify({ platform: 'youtube', checked: true, ok: false, reasons: ['Last upload 200 days ago'], subscribers: 5400 });
  const igChk = JSON.stringify({ platform: 'instagram', checked: false, ok: true, reasons: [] });
  h.eq('a failed check is refused', String(await call(a, `select apply_creator(5400, 'https://youtube.com/@yt', '', null, $1::jsonb)`, [badChk])).includes('Last upload 200 days ago'), true);
  const appA = await call(a, `select apply_creator(5400, 'https://youtube.com/@yt', '', null, $1::jsonb)`, [okChk]);
  h.eq('a passing YouTube check applies without a recent post', typeof appA === 'string' && appA.length === 36, true);
  const appB = await call(b, `select apply_creator(2000, 'https://instagram.com/ig', '', 'https://instagram.com/p/abc', $1::jsonb)`, [igChk]);
  h.eq('instagram applies without any post (567); a post link from an old client is dropped', [typeof appB === 'string' && appB.length === 36, await call(b, `select recent_link from creator_applications where id = $1`, [appB])], [true, 'ok']);
  h.eq('check json stored, only known keys', (await h.q(`select channel_check->>'platform' p, channel_check ? 'evil' e from creator_applications where id = $1`, [appA]))[0], { p: 'youtube', e: false });
  h.eq('oversized check refused', await call(b, `select apply_creator(2000, 'https://instagram.com/ig', '', null, $1::jsonb)`, [JSON.stringify({ platform: 'instagram', checked: false, ok: true, reasons: Array(5).fill('x'.repeat(200)), handle: 'y'.repeat(100), evil: 'z'.repeat(9000) })]), 'You already have an application waiting for review');

  // 30-day rule
  await call(admin, `select review_creator($1, true, 1, '')`, [appA]);
  const appC = await call(c, `select apply_creator(2000, 'https://youtube.com/@quiet', '', null, $1::jsonb)`, [okChk]);
  await call(admin, `select review_creator($1, true, 1, '')`, [appC]);
  const appD = await call(d, `select apply_creator(2000, 'https://youtube.com/@active', '', null, $1::jsonb)`, [okChk]);
  await call(admin, `select review_creator($1, true, 2, '')`, [appD]);
  const dl = await call(a, `select creator_deadline($1)`, [a]);
  h.eq('deadline = approval + 30 days', Math.round((new Date(dl) - Date.now()) / 864e5), 30);
  h.eq('non-creators have no deadline', await call(b, `select creator_deadline($1)`, [b]), 'ok');
  h.eq('members can not run the sweep', String(await call(a, `select creator_inactive_sweep()`)).includes('permission denied'), true);
  h.eq('fresh approvals: sweep removes nobody', Number(await one(`select creator_inactive_sweep()`)), 0);
  await h.q(`update creator_applications set reviewed_at = now() - interval '31 days' where id in ($1, $2)`, [appC, appD]);
  await h.q(`update mod_log set created_at = now() - interval '31 days' where target_id in ($1, $2)`, [c, d]);
  const sub = await call(d, `select submit_creator_content('https://youtube.com/watch?v=dQw4w9WgXcQ', '', 10)`);
  h.eq('active creator sends a piece', typeof sub === 'string' && sub.length === 36 ? true : sub, true);
  h.eq('active creator: deadline moves to last piece + 30', Math.round((new Date(await call(d, `select creator_deadline($1)`, [d])) - Date.now()) / 864e5), 30);
  h.eq('sweep removes the quiet one only', Number(await one(`select creator_inactive_sweep()`)), 1);
  h.eq('quiet: badge gone, logged', [await one(`select badges from profiles where id = $1`, [c]), (await h.q(`select reason from mod_log where target_id = $1 and action = 'creator_revoked'`, [c]))[0].reason.includes('30 days')], [[], true]);
  h.eq('active and fresh keep theirs', [await one(`select badges from profiles where id = $1`, [d]), await one(`select badges from profiles where id = $1`, [a])], [['creator_2'], ['creator_1']]);
  h.eq('second sweep: nothing more', Number(await one(`select creator_inactive_sweep()`)), 0);
  h.eq('the quiet one can apply again right away', typeof (await call(c, `select apply_creator(2000, 'https://youtube.com/@quiet', '', null, $1::jsonb)`, [okChk])) === 'string', true);
}
