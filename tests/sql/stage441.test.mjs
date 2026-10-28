// 441: Promoted bots. Builds on 024 with the flag migrations and stand-ins for the live bots table, bans, staff and
// mod_log, then checks who can book, see and end promotions, the 4 spot queue and what promoted_bots() shows.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export const STANDINS = `
alter table public.profiles add column if not exists display_name text;
create table if not exists public.bots (
  id uuid primary key, owner_id uuid not null, name text not null, tag text, description text default '', category text,
  public boolean not null default false, unlisted boolean, avatar_path text, support_invite text, real_servers int,
  verified_at timestamptz, created_at timestamptz default now());
alter table public.bots enable row level security;
create policy "bots visible" on public.bots for select to authenticated using (owner_id = auth.uid() or public);
create or replace function public.bot_real_server_count(b uuid) returns bigint language sql stable as $$ select 0::bigint $$;
create table if not exists public.site_admins (user_id uuid primary key);
create table if not exists public.site_moderators (user_id uuid primary key);
create table if not exists public.site_bans (user_id uuid primary key);
alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = auth.uid()) $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod() $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())) $$;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select t ~* 'slurword' $$;
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid, reason text default '', created_at timestamptz default now());
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('441_bot_promoted.sql');
  await h.ok('441 runs', () => h.db.exec(MIG));
  await h.ok('441 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'bot_promoted'`)).mode, 'test');

  const a = await h.signup('a@test.dev', 'alice'); // owner of the bots
  const b = await h.signup('b@test.dev', 'bob'); // someone else
  const m = await h.signup('m@test.dev', 'mod'); // site mod
  const z = await h.signup('z@test.dev', 'admin'); // site admin
  const botIds = [];
  for (let i = 0; i < 7; i++) botIds.push(await h.signup(`bot${i}@test.dev`, `bot${i}`)); // bots have profiles
  const [b0, b1, b2, b3, b4, bPriv, bNew] = botIds;
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [m]);
  await h.q(`insert into site_admins values ($1)`, [z]);
  for (const id of [b0, b1, b2, b3, b4]) await h.q(`insert into bots (id, owner_id, name, public, verified_at) values ($1, $2, $3, true, now())`, [id, a, 'Bot ' + id.slice(0, 4)]);
  await h.q(`insert into bots (id, owner_id, name, public, unlisted, verified_at) values ($1, $2, 'Private', false, true, now())`, [bPriv, a]);
  await h.q(`insert into bots (id, owner_id, name, public) values ($1, $2, 'Unchecked', true)`, [bNew, a]);
  // Flags: bot_verified on for everyone, bot_promoted in test for alice only.
  await h.q(`insert into feature_flags (key, label, mode) values ('bot_verified', 'x', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  await h.q(`update feature_flags set users = array[$1]::uuid[], servers = '{}' where key = 'bot_promoted'`, [a]);

  // ---- who can book
  h.eq('eligible: verified, listed', (await h.one(`select bot_promo_ok($1) ok`, [b0])).ok, true);
  h.eq('not eligible: private', (await h.one(`select bot_promo_ok($1) ok`, [bPriv])).ok, false);
  h.eq('not eligible: unverified', (await h.one(`select bot_promo_ok($1) ok`, [bNew])).ok, false);
  for (const who of [a, b, m, z]) {
    await h.as(who);
    await h.fails('only service_role books', `select book_bot_promotion($1, 'stripe', 'evt_x', null, 7)`, [b0]);
    await h.fails('bot_promo_ok is not callable', `select bot_promo_ok($1)`, [b0]);
    await h.fails('no direct inserts', `insert into bot_promotions (bot_id, ends_at) values ($1, now() + interval '7 days')`, [b0]);
  }
  await h.as(null);
  await h.fails('anon cannot book', `select book_bot_promotion($1, 'stripe', 'evt_x', null, 7)`, [b0]);

  // ---- service_role books (the webhook); 4 spots, the 5th queues
  await h.admin();
  await h.db.exec(`set role service_role`);
  for (const [i, id] of [b0, b1, b2, b3].entries()) await h.q(`select book_bot_promotion($1, 'stripe', $2, null, 7)`, [id, `evt_${i}`]);
  await h.fails('same Stripe event books once', `select book_bot_promotion($1, 'stripe', 'evt_0', null, 7)`, [b4]);
  const queued = await h.one(`select book_bot_promotion($1, 'stripe', 'evt_4', null, 7) - now() > interval '6 days' q`, [b4]);
  h.eq('5th bot queues until a spot frees', queued.q, true);
  const again = await h.one(`select book_bot_promotion($1, 'stripe', 'evt_5', null, 7) - now() > interval '6 days' q`, [b0]);
  h.eq('second buy for the same bot starts after its first', again.q, true);
  await h.fails('days capped', `select book_bot_promotion($1, 'stripe', 'evt_6', null, 90)`, [b0]);
  await h.db.exec(`reset role`);

  // ---- what /bots shows
  await h.as(a);
  h.eq('flagged user sees the 4 live ones', (await h.q(`select id from promoted_bots(6) order by id`)).map((r) => r.id), [b0, b1, b2, b3].sort());
  h.eq('promoted_bots caps at the limit', (await h.q(`select id from promoted_bots(2)`)).length, 2);
  await h.as(b);
  h.eq('outside the test group: nothing', (await h.q(`select id from promoted_bots(6)`)).length, 0);
  await h.as(null);
  h.eq('anon outside the test group: nothing', (await h.q(`select id from promoted_bots(6)`)).length, 0);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'bot_promoted'`);
  await h.as(null);
  h.eq('anon sees them once published', (await h.q(`select id from promoted_bots(6)`)).length, 4);
  await h.admin();
  await h.q(`insert into site_bans (user_id) values ($1)`, [b1]);
  await h.q(`update bots set public = false where id = $1`, [b2]);
  await h.as(b);
  h.eq('banned and unlisted bots drop out', (await h.q(`select id from promoted_bots(6) order by id`)).map((r) => r.id), [b0, b3].sort());
  await h.admin();
  await h.q(`insert into site_bans (user_id) values ($1)`, [a]);
  await h.as(b);
  h.eq('banned owner: all their bots drop out', (await h.q(`select id from promoted_bots(6)`)).length, 0);
  await h.admin();
  await h.q(`delete from site_bans`);
  await h.q(`update bots set public = true where id = $1`, [b2]);
  await h.q(`update bot_promotions set ends_at = now() - interval '1 minute', starts_at = now() - interval '8 days' where bot_id = $1`, [b3]);
  await h.as(b);
  h.eq('expired ones drop off', (await h.q(`select id from promoted_bots(6) order by id`)).map((r) => r.id), [b0, b1, b2].sort());

  // ---- numbers
  const pid0 = (await h.one(`select promo_id from promoted_bots(6) where id = $1`, [b0])).promo_id;
  await h.ok('view counted', () => h.q(`select bot_promo_event(array[$1]::uuid[], 'view')`, [pid0]));
  await h.ok('bad kind ignored', () => h.q(`select bot_promo_event(array[$1]::uuid[], 'join')`, [pid0]));
  await h.as(null);
  await h.fails('anon cannot count', `select bot_promo_event(array[$1]::uuid[], 'view')`, [pid0]);
  await h.admin();
  h.eq('one view', (await h.one(`select views from bot_promotions where id = $1`, [pid0])).views, 1);

  // ---- who sees the rows
  await h.as(a);
  h.eq('owner sees their promotions', (await h.q(`select id from bot_promotions`)).length, 6);
  await h.fails('owner cannot read who ended it', `select ended_by from bot_promotions`);
  await h.fails('owner cannot read the Stripe event', `select stripe_event from bot_promotions`);
  h.eq('owner reads availability', (await h.one(`select (bot_promo_availability($1) ->> 'slots')::int n`, [b0])).n, 4);
  await h.fails('no direct updates', `update bot_promotions set ends_at = now() + interval '1 year'`);
  await h.as(b);
  h.eq('others see none', (await h.q(`select id from bot_promotions`)).length, 0);
  await h.fails('others cannot read availability', `select bot_promo_availability($1)`, [b0]);
  await h.fails('others cannot list for staff', `select * from staff_bot_promotions()`);
  await h.fails('others cannot end one', `select staff_end_bot_promotion($1, 'x')`, [pid0]);
  await h.fails('others cannot promote free', `select admin_promote_bot($1, 7)`, [b0]);
  await h.as(null);
  await h.fails('anon cannot read rows', `select id from bot_promotions`);

  // ---- staff
  await h.as(m);
  h.eq('mod lists running and queued', (await h.q(`select id from staff_bot_promotions()`)).length, 5);
  await h.fails('mod must say why', `select staff_end_bot_promotion($1, '  ')`, [pid0]);
  await h.ok('mod ends one', () => h.q(`select staff_end_bot_promotion($1, 'scam bot')`, [pid0]));
  await h.fails('ending twice errors', `select staff_end_bot_promotion($1, 'again')`, [pid0]);
  await h.fails('mod cannot promote free', `select admin_promote_bot($1, 7)`, [b0]);
  const q4 = (await h.one(`select id from staff_bot_promotions() where bot_id = $1`, [b4])).id;
  await h.ok('mod ends a queued one before it starts', () => h.q(`select staff_end_bot_promotion($1, 'refund')`, [q4]));
  await h.admin();
  h.eq('ended ones are logged', (await h.q(`select action, reason from mod_log where actor = $1 order by created_at, reason`, [m])).map((r) => `${r.action}:${r.reason}`).sort(), ['bot_promo_ended:refund', 'bot_promo_ended:scam bot']);
  h.eq('queued end has a valid window', (await h.one(`select starts_at <= ends_at ok from bot_promotions where id = $1`, [q4])).ok, true);
  await h.as(z);
  await h.fails('admin cannot promote a private bot', `select admin_promote_bot($1, 7)`, [bPriv]);
  await h.ok('admin promotes free', () => h.q(`select admin_promote_bot($1, 3)`, [b3]));
  await h.admin();
  h.eq('free promo is source admin', (await h.one(`select source from bot_promotions where bot_id = $1 order by created_at desc limit 1`, [b3])).source, 'admin');

  // ---- queue checks the whole window: a spot freed early must not let a 5th bot overlap a queued one
  await h.q(`delete from bot_promotions`);
  await h.q(`update bots set public = true, unlisted = false where id = $1`, [bPriv]);
  for (const id of [b1, b2, b3]) await h.q(`insert into bot_promotions (bot_id, starts_at, ends_at) values ($1, now() - interval '1 day', now() + interval '10 days')`, [id]);
  await h.q(`insert into bot_promotions (bot_id, starts_at, ends_at) values ($1, now() + interval '2 days', now() + interval '9 days')`, [b4]);
  await h.db.exec(`set role service_role`);
  const st = await h.one(`select extract(epoch from book_bot_promotion($1, 'stripe', 'evt_q', null, 7) - now()) / 86400 d`, [bPriv]);
  await h.db.exec(`reset role`);
  h.eq('starts when the queued one ends, not now', Math.round(Number(st.d)), 9);
  const peak = await h.one(`select max((select count(distinct o.bot_id) from bot_promotions o where o.starts_at <= x.t and o.ends_at > x.t)) n
    from (select starts_at t from bot_promotions) x`);
  h.eq('never more than 4 at once', Number(peak.n), 4);
}
