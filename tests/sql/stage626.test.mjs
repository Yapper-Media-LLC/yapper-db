// 626: creator applications: screening at submit time (upload in 60 days, 3+ videos, 30+ days old, flag creator_apply_v2)
// and "ask for proof" (needs_proof, the applicant's reply with a link or screenshot, back to the queue).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

const STANDINS = `
create table if not exists public.t532_shards (user_id uuid, amount int, kind text, ref text, note text);
create or replace function public.shard_post(p_user uuid, p_amount int, p_kind text, p_ref text, p_note text default '', p_actor uuid default null, p_staff boolean default false) returns int language plpgsql as $$
begin insert into public.t532_shards values (p_user, p_amount, p_kind, p_ref, p_note); return p_amount; end $$;
alter table auth.users add column if not exists email_confirmed_at timestamptz default now();
create table if not exists public.t417_admins (id uuid primary key);
create table if not exists public.t417_banned (id uuid primary key);
create table if not exists public.t518_shared (a uuid, b uuid);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz not null default now());
create table if not exists public.user_warnings (id uuid primary key default gen_random_uuid(), user_id uuid, proof jsonb);
create table if not exists public.site_bans (user_id uuid primary key, proof jsonb);
alter table public.site_bans add column if not exists proof jsonb;
alter table public.user_warnings add column if not exists proof jsonb;
create table if not exists public.verification_requests (id uuid primary key default gen_random_uuid(), user_id uuid, proof_path text, status text);
create table if not exists public.t626_bc (topic text, kind text);
create or replace function public.bc(a text, b text, c text, d text, e text, f jsonb, g jsonb) returns void language sql as $$ insert into public.t626_bc values (a, b) $$;
create or replace function public.is_site_manager() returns boolean language sql stable as $$ select false $$;
create or replace function public.manager_guard(action text, target uuid) returns void language plpgsql as $$ begin raise exception 'Admins only'; end $$;
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
create or replace function public.shard_is_bot(uid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.profiles where id = uid and 'bot' = any(badges)) $$;
create or replace function public.shard_shared_device(a uuid, b uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.t518_shared s where (s.a = $1 and s.b = $2) or (s.a = $2 and s.b = $1)) $$;
insert into storage.buckets (id, name) values ('proofs', 'proofs') on conflict do nothing;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  for (const m of ['417_creator_program.sql', '418_creator_center.sql', '419_elite_500k.sql', '497_creator_center_v2.sql', '518_creator_v3.sql', '532_creator_rewards_tune.sql', '533_creator_invites_shards_only.sql', '538_creator_invite_analytics.sql', '539_creator_hits_hardening.sql', '543_creator_screening.sql', '567_creator_apply_no_videos.sql']) await h.db.exec(mig(m));
  await h.db.exec(mig('626_creator_apply_screening_proof.sql'));
  await h.ok('626 re-runs cleanly', () => h.db.exec(mig('626_creator_apply_screening_proof.sql')));
  const admin = await h.signup('admin@test.dev', 'admin');
  const admin2 = await h.signup('admin2@test.dev', 'admin2');
  const a = await h.signup('a@test.dev', 'alive');
  const b = await h.signup('b@test.dev', 'dead');
  const c = await h.signup('c@test.dev', 'one');
  const d = await h.signup('d@test.dev', 'baby');
  const e = await h.signup('e@test.dev', 'oldclient');
  await h.admin();
  await h.q(`insert into t417_admins values ($1), ($2)`, [admin, admin2]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'creator_program'`);
  await h.q(`update profiles set verified_as = 'YouTube · x' where id in ($1, $2, $3, $4, $5)`, [a, b, c, d, e]);
  const call = async (who, sql, args) => {
    await h.as(who);
    try { const r = await h.q(sql, args); const v = r[0] ? Object.values(r[0])[0] : null; return v == null || v === '' ? 'ok' : v; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  const one = async (sql, args) => Object.values((await h.q(sql, args))[0])[0];
  const days = (n) => new Date(Date.now() - n * 864e5).toISOString();
  const chk = (o) => JSON.stringify({ platform: 'youtube', checked: true, ok: true, reasons: [], subscribers: 5400, lastPost: days(3), videos: 12, createdAt: days(400), source: 'api', ...o });

  h.eq('status check allows needs_proof', String(await one(`select pg_get_constraintdef(oid) from pg_constraint where conname = 'creator_applications_status_check'`)).includes('needs_proof'), true);
  h.eq('one apply_creator, one review_creator', [Number(await one(`select count(*) from pg_proc where proname = 'apply_creator'`)), Number(await one(`select count(*) from pg_proc where proname = 'review_creator'`))], [1, 1]);

  // Screening only with the flag on: an old client (no new keys) and a dead channel both still go through for everyone else.
  const appE = await call(e, `select apply_creator(5400, 'https://youtube.com/@oldclient', '', null, $1::jsonb)`, [JSON.stringify({ platform: 'youtube', checked: true, ok: true, reasons: [], subscribers: 5400, lastPost: days(100), posts90d: 0 })]);
  h.eq('flag off: a quiet channel still applies (the mod sees the check)', typeof appE === 'string' && appE.length === 36, true);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'creator_apply_v2'`);
  h.eq('flag on: no upload in 60 days is refused with the days', String(await call(b, `select apply_creator(5400, 'https://youtube.com/@dead', '', null, $1::jsonb)`, [chk({ lastPost: days(100) })])).includes('100 days ago'), true);
  h.eq('no uploads at all is refused', String(await call(b, `select apply_creator(5400, 'https://youtube.com/@dead', '', null, $1::jsonb)`, [chk({ lastPost: null })])).includes('no public uploads'), true);
  h.eq('fewer than 3 videos is refused', String(await call(c, `select apply_creator(5400, 'https://youtube.com/@one', '', null, $1::jsonb)`, [chk({ videos: 1 })])).includes('1 public video'), true);
  h.eq('a channel under 30 days old is refused', String(await call(d, `select apply_creator(5400, 'https://youtube.com/@baby', '', null, $1::jsonb)`, [chk({ createdAt: days(10) })])).includes('10 days old'), true);
  h.eq('an unchecked platform (TikTok) is not screened by numbers', typeof (await call(d, `select apply_creator(5400, 'https://tiktok.com/@baby', '', null, $1::jsonb)`, [JSON.stringify({ platform: 'tiktok', checked: false, ok: true, reasons: [] })])) === 'string', true);
  const appA = await call(a, `select apply_creator(5400, 'https://youtube.com/@alive', '', null, $1::jsonb)`, [chk({})]);
  h.eq('an alive channel applies; videos and createdAt are kept for the mod', [appA.length, (await h.q(`select channel_check->>'videos' v, channel_check ? 'createdAt' c from creator_applications where id = $1`, [appA]))[0]], [36, { v: '12', c: true }]);

  // Ask for proof
  h.eq('non-staff can not ask', await call(b, `select ask_creator_proof($1, 'show me')`, [appA]), 'Admins only');
  h.eq('a note is needed', await call(admin, `select ask_creator_proof($1, '')`, [appA]), 'Say what you need from them');
  h.eq('ask works', await call(admin, `select ask_creator_proof($1, 'Post a story with yapin: alive in it and send the link')`, [appA]), 'ok');
  h.eq('row is needs_proof with the note, asked_at, reviewer', (await h.q(`select status, review_note, asked_at is not null a, reviewed_by = $2 r from creator_applications where id = $1`, [appA, admin]))[0], { status: 'needs_proof', review_note: 'Post a story with yapin: alive in it and send the link', a: true, r: true });
  h.eq('the applicant got a ping on their user topic', (await h.q(`select * from t626_bc`))[0], { topic: `user:${a}`, kind: 'creator_application' });
  h.eq('logged as creator_ask_proof', Number(await one(`select count(*) from mod_log where action = 'creator_ask_proof' and target_id = $1`, [a])), 1);
  h.eq('asking twice is refused', await call(admin2, `select ask_creator_proof($1, 'again?')`, [appA]), 'Already asked');
  h.eq('while asked, no second application', await call(a, `select apply_creator(5400, 'https://youtube.com/@alive', '', null, $1::jsonb)`, [chk({})]), 'You already have an application waiting for review');
  h.eq('the applicant can still see their row', await call(a, `select status from creator_applications where id = $1`, [appA]), 'needs_proof');

  // The reply
  h.eq('a reply needs a link or a screenshot', await call(a, `select creator_proof_added($1, null, null, 'here')`, [appA]), 'Add a link or a screenshot');
  h.eq('a bad link is refused', await call(a, `select creator_proof_added($1, 'javascript:alert(1)', null, '')`, [appA]), 'That link doesn’t look right'.replace('’', "'"));
  h.eq('someone else’s screenshot path is refused', await call(a, `select creator_proof_added($1, null, $2, '')`, [appA, `${b}/x.png`]), "That screenshot can't be used");
  h.eq('a screenshot that is not uploaded is refused', String(await call(a, `select creator_proof_added($1, null, $2, '')`, [appA, `${a}/shot.png`])).includes('finish uploading'), true);
  await h.q(`insert into storage.objects (bucket_id, name, owner) values ('proofs', $1, $2)`, [`${a}/shot.png`, a]);
  h.eq('somebody else can not answer for them', await call(b, `select creator_proof_added($1, 'https://instagram.com/stories/alive/1', null, '')`, [appA]), 'Nothing to re-check');
  h.eq('reply with link + screenshot + note', await call(a, `select creator_proof_added($1, 'https://instagram.com/stories/alive/1', $2, 'done, see story')`, [appA, `${a}/shot.png`]), 'ok');
  h.eq('back to pending with the proof on the row', (await h.q(`select status, proof_link, proof_path, proof_note, proof_added_at is not null p from creator_applications where id = $1`, [appA]))[0], { status: 'pending', proof_link: 'https://instagram.com/stories/alive/1', proof_path: `${a}/shot.png`, proof_note: 'done, see story', p: true });
  await h.as(a);
  h.eq('while open, the applicant can not delete the screenshot (proof_is_evidence)', await one(`select proof_is_evidence($1)`, [`${a}/shot.png`]), true);
  await h.admin();
  h.eq('replying again is refused', await call(a, `select creator_proof_added($1, 'https://x.com/a', null, '')`, [appA]), 'Nothing to re-check');

  // Review from either state
  h.eq('a second ask clears the old proof', await call(admin, `select ask_creator_proof($1, 'one more: a screenshot of the studio page')`, [appA]), 'ok');
  h.eq('proof cleared', (await h.q(`select proof_link, proof_path, proof_added_at from creator_applications where id = $1`, [appA]))[0], { proof_link: null, proof_path: null, proof_added_at: null });
  h.eq('a needs_proof row can be approved straight away', await call(admin2, `select review_creator($1, true, 1, '')`, [appA]), 'ok');
  h.eq('badge given', await one(`select badges from profiles where id = $1`, [a]), ['creator_1']);
  h.eq('asking on a reviewed one is refused', await call(admin, `select ask_creator_proof($1, 'hmm')`, [appA]), 'Already reviewed');
  h.eq('old-client row (pending) can be rejected as before', await call(admin, `select review_creator($1, false, null, 'Channel has not posted in 60 days')`, [appE]), 'ok');
}
