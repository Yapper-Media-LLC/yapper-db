// 634: Art Managers and Dev Managers (flag area_managers, per user). Stage 24 plus 537's stand-ins (profiles badges,
// site_* tables, mod_log, mod_guard with the live "Moderators only" anchor, admin_set_badge), plus trimmed copies of the
// deco and bot functions 634 patches, carrying their live anchor lines (Oct 28, pg_get_functiondef).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '634_area_managers.sql'), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export const MORE = `
create table if not exists public.community_decos (id uuid primary key default gen_random_uuid(), kind text not null default 'deco', name text not null,
  artist_id uuid not null, path text not null, status text not null default 'pending', review_note text, reviewed_by uuid, reviewed_at timestamptz,
  created_at timestamptz not null default now(), price int);
alter table public.community_decos enable row level security;
grant select on public.community_decos to authenticated;
create policy "approved ones, your own, all for staff" on public.community_decos for select
  using (status = 'approved' or artist_id = (select auth.uid()) or (select is_site_admin()) or (select is_site_mod()));
create table if not exists public.community_deco_checks (deco_id uuid primary key, verdict text, cleared_by uuid, cleared_at timestamptz, cleared_note text);
create table if not exists public.bots (id uuid primary key default gen_random_uuid(), owner_id uuid, name text not null, public boolean not null default false,
  unlisted boolean not null default false, verified_at timestamptz, review_note text, submitted_at timestamptz, created_at timestamptz not null default now(),
  last_used_at timestamptz, posts bigint not null default 0, real_servers int);
create table if not exists public.bot_promotions (id uuid primary key default gen_random_uuid(), bot_id uuid not null, starts_at timestamptz not null default now(),
  ends_at timestamptz not null, ended_by uuid);
create table if not exists public.shard_ledger (id bigserial primary key, user_id uuid not null, amount int not null, kind text not null, ref text, note text,
  actor uuid, created_at timestamptz not null default now());
create or replace function public.can_review_bots() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or (public.is_site_mod() and public.feature_on('mod_bot_review', null)); $$;
create or replace function public.review_community_deco(p_id uuid, p_status text, p_note text default '') returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare d public.community_decos;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  perform public.mod_guard(case when p_status = 'removed' then 'deco_takedown' else 'deco_review' end, null, p_note);
  if p_status not in ('approved', 'rejected', 'removed') then raise exception 'Bad status'; end if;
  select * into d from public.community_decos where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if d.artist_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  update public.community_decos set status = p_status, review_note = p_note, reviewed_by = (select auth.uid()), reviewed_at = now() where id = p_id;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'deco_' || p_status, d.artist_id, left(d.name, 300));
end; $function$;
create or replace function public.staff_flagged_decos() returns table(id uuid, name text)
 language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  return query select d.id, d.name from public.community_deco_checks c join public.community_decos d on d.id = c.deco_id where c.cleared_at is null;
end; $function$;
create or replace function public.staff_clear_deco_check(p_id uuid, p_note text) returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  perform public.mod_guard('deco_review', null, p_note);
  update public.community_deco_checks set cleared_by = (select auth.uid()), cleared_at = now(), cleared_note = p_note where deco_id = p_id and cleared_at is null;
end; $function$;
create or replace function public.admin_verify_bot(bid uuid, ok boolean, note text default null, was_private boolean default null) returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare b public.bots;
begin
  if not public.can_review_bots() then raise exception 'Moderators only'; end if;
  perform public.mod_guard('bot_review', null, note);
  select * into b from public.bots where id = bid for update;
  if b.id is null then raise exception 'No such bot'; end if;
  if b.owner_id = auth.uid() and not public.is_site_admin() then raise exception 'You can''t review your own bot'; end if;
  if not (b.public or b.unlisted) then raise exception 'That bot isn''t waiting for review any more'; end if;
  if ok then update public.bots set verified_at = now(), review_note = null where id = bid;
  else update public.bots set public = false, unlisted = false, verified_at = null, review_note = left(coalesce(note, 'Not approved'), 300) where id = bid; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when ok then 'bot_verified' else 'bot_rejected' end, bid, coalesce(note, ''));
end $function$;
create or replace function public.staff_bot_promotions() returns table(id uuid, bot_id uuid)
 language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query select p.id, p.bot_id from public.bot_promotions p where p.ends_at > now();
end $function$;
create or replace function public.staff_end_bot_promotion(pid uuid, why text) returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare v_bot uuid;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  perform public.mod_guard('bot_promo', null, why);
  update public.bot_promotions set ends_at = now(), ended_by = (select auth.uid()) where id = pid and ends_at > now() returning bot_id into v_bot;
  if v_bot is null then raise exception 'That promotion already ended'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'bot_promo_ended', v_bot, left(why, 500));
end $function$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`634 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.q(`insert into feature_flags (key, label, mode) values ('head_mods', 'x', 'everyone'), ('head_mod_badges', 'x', 'everyone'), ('mod_bot_review', 'x', 'everyone') on conflict (key) do nothing`);
  await h.ok('634 runs', () => h.db.exec(MIG));
  await h.ok('634 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'area_managers'`)).mode, 'test');
  const once = async (fn, marker) => (await h.one(`select (length(prosrc) - length(replace(prosrc, $2, ''))) / length($2) n from pg_proc where proname = $1`, [fn, marker])).n;
  h.eq('mod_guard patched once', await once('mod_guard', 'area_manager_may'), 1);
  h.eq('admin_set_badge patched once', await once('admin_set_badge', 'is_art_manager'), 1);
  h.eq('review_community_deco patched once', await once('review_community_deco', 'is_art_manager'), 1);
  h.eq('staff_end_bot_promotion patched once', await once('staff_end_bot_promotion', 'is_dev_manager'), 1);

  const admin = await h.signup('admin@test.dev', 'boss');
  const art = await h.signup('art@test.dev', 'artmgr');
  const dev = await h.signup('dev@test.dev', 'devmgr');
  const mod = await h.signup('mod@test.dev', 'modder');
  const u = await h.signup('u@test.dev', 'someone');
  const u2 = await h.signup('u2@test.dev', 'someone2');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'area_managers'`, [admin]); // stands in for Antic
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);
  const badges = async (uid) => (await h.one(`select badges from profiles where id = $1`, [uid])).badges;
  const areas = async (uid) => { await h.as(uid); const r = (await h.one(`select my_areas() a`)).a; await h.admin(); return r; };

  // Only admins give the roles, and only with the flag on.
  await h.as(mod);
  h.eq('mod cannot give Art Manager', await err(`select admin_set_area_manager($1, 'art', true)`, [u]), 'Admins only');
  await h.as(admin);
  h.eq('unknown area refused', await err(`select admin_set_area_manager($1, 'ops', true)`, [art]), 'Unknown role');
  h.eq('admins do not need it', await err(`select admin_set_area_manager($1, 'art', true)`, [admin]), 'Admins don\'t need the role');
  await h.ok('admin makes an Art Manager', () => h.q(`select admin_set_area_manager($1, 'art', true, 'draws well')`, [art]));
  await h.ok('admin makes a Dev Manager', () => h.q(`select admin_set_area_manager($1, 'dev', true)`, [dev]));
  await h.ok('giving it twice is quiet', () => h.q(`select admin_set_area_manager($1, 'dev', true)`, [dev]));
  await h.admin();
  h.eq('logged once each', (await h.one(`select count(*)::int n from mod_log where action in ('art_manager_added', 'dev_manager_added')`)).n, 2);
  h.eq('art badge given', (await badges(art)).includes('art_manager'), true);
  h.eq('dev badge given', (await badges(dev)).includes('dev_manager'), true);
  h.eq('not a moderator', (await h.one(`select count(*)::int n from site_moderators where user_id in ($1, $2)`, [art, dev])).n, 0);

  // The flag is per user: off for them, the role sleeps.
  h.eq('flag off: no areas', await areas(art), []);
  await h.as(art);
  h.eq('flag off: cannot review', await err(`select review_community_deco(gen_random_uuid(), 'approved')`), 'Staff only');
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid || $2::uuid where key = 'area_managers'`, [art, dev]);
  h.eq('flag on: art', await areas(art), ['art']);
  h.eq('flag on: dev', await areas(dev), ['dev']);
  h.eq('plain mod: none', await areas(mod), []);
  h.eq('plain user: none', await areas(u), []);

  // Art Manager: decorations and the Artist badge, nothing else.
  await h.admin();
  const deco = (await h.one(`insert into community_decos (name, artist_id, path) values ('Hat', $1, 'a/hat.png') returning id`, [u])).id;
  const own = (await h.one(`insert into community_decos (name, artist_id, path) values ('Mine', $1, 'a/mine.png') returning id`, [art])).id;
  const flagged = (await h.one(`insert into community_decos (name, artist_id, path) values ('Copy', $1, 'a/copy.png') returning id`, [u2])).id;
  await h.q(`insert into community_deco_checks (deco_id, verdict) values ($1, 'suspect')`, [flagged]);
  await h.as(art);
  h.eq('art manager reads pending decos', (await h.one(`select count(*)::int n from community_decos where status = 'pending'`)).n, 3);
  await h.ok('art manager approves a deco', () => h.q(`select review_community_deco($1, 'approved')`, [deco]));
  h.eq('not their own', await err(`select review_community_deco($1, 'approved')`, [own]), 'Someone else has to review your own');
  h.eq('art manager sees the flagged one', (await h.one(`select count(*)::int n from staff_flagged_decos()`)).n, 1);
  await h.ok('art manager clears a check', () => h.q(`select staff_clear_deco_check($1, 'their own style, fine')`, [flagged]));
  await h.ok('art manager gives Artist', () => h.q(`select admin_set_badge($1, 'artist', true)`, [u]));
  await h.ok('art manager takes Artist', () => h.q(`select admin_set_badge($1, 'artist', false)`, [u]));
  h.eq('art manager cannot give partner', await err(`select admin_set_badge($1, 'partner', true)`, [u]), 'Admins only');
  h.eq('art manager cannot give bug_hunter', await err(`select admin_set_badge($1, 'bug_hunter', true)`, [u]), 'Admins only');
  h.eq('art manager cannot badge themselves', await err(`select admin_set_badge($1, 'artist', true)`, [art]), 'Not yourself');
  h.eq('art manager cannot badge a mod', await err(`select admin_set_badge($1, 'artist', true)`, [mod]), 'You can\'t moderate an admin or another moderator');
  h.eq('art manager cannot review bots', await err(`select admin_verify_bot(gen_random_uuid(), true)`), 'Moderators only');
  h.eq('art manager cannot see bot promotions', await err(`select * from staff_bot_promotions()`), 'Staff only');
  h.eq('art manager cannot suspend bots', await err(`select staff_suspend_bot(gen_random_uuid(), 'spamming people')`), 'Admins only');
  h.eq('art manager cannot ban', await err(`select site_ban($1, 'spam bot account')`, [u]), 'Admins only');
  h.eq('art manager cannot change staff', await err(`select admin_set_developer($1, true)`, [u]), 'Admins only');
  await h.ok('art manager reads the sale report', () => h.q(`select staff_deco_sales(30)`));
  h.eq('art manager cannot read the dev report', await err(`select staff_dev_report()`), 'Admins only');
  // Hourly cap through mod_guard: 60 reviews an hour like a mod (537's stand-in counts the action name itself).
  await h.admin();
  await h.q(`insert into mod_log (actor, action, target_id) select $1, 'deco_review', $2 from generate_series(1, 60)`, [art, u]);
  const more = (await h.one(`insert into community_decos (name, artist_id, path) values ('More', $1, 'a/more.png') returning id`, [u])).id;
  await h.as(art);
  h.eq('60 reviews an hour (537 stand-in wording)', await err(`select review_community_deco($1, 'approved')`, [more]), 'hourly limit');
  await h.admin();
  await h.q(`update mod_log set created_at = now() - interval '2 hours' where actor = $1`, [art]);

  // Dev Manager: bots, nothing else.
  await h.admin();
  const bot = (await h.one(`insert into bots (owner_id, name, public, submitted_at) values ($1, 'Helper', true, now()) returning id`, [u])).id;
  const ownBot = (await h.one(`insert into bots (owner_id, name, public, submitted_at) values ($1, 'My bot', true, now()) returning id`, [dev])).id;
  const live = (await h.one(`insert into bots (owner_id, name, public, verified_at) values ($1, 'Live', true, now()) returning id`, [u2])).id;
  const promo = (await h.one(`insert into bot_promotions (bot_id, ends_at) values ($1, now() + interval '3 days') returning id`, [live])).id;
  const adminBot = (await h.one(`insert into bots (owner_id, name, public, verified_at) values ($1, 'Official', true, now()) returning id`, [admin])).id;
  await h.as(dev);
  await h.ok('dev manager verifies a bot', () => h.q(`select admin_verify_bot($1, true)`, [bot]));
  h.eq('not their own bot', await err(`select admin_verify_bot($1, true)`, [ownBot]), 'You can\'t review your own bot');
  h.eq('dev manager sees promotions', (await h.one(`select count(*)::int n from staff_bot_promotions()`)).n, 1);
  h.eq('dev manager cannot review decos', await err(`select review_community_deco($1, 'approved')`, [own]), 'Staff only');
  h.eq('dev manager cannot give Artist', await err(`select admin_set_badge($1, 'artist', true)`, [u]), 'Admins only');
  h.eq('dev manager cannot read the sale report', await err(`select staff_deco_sales()`), 'Admins only');
  h.eq('dev manager cannot read pending decos', (await h.one(`select count(*)::int n from community_decos where status = 'pending'`)).n, 0);
  await h.ok('dev manager reads the dev report', async () => {
    const r = (await h.one(`select staff_dev_report() r`)).r;
    if (r.bots !== 4 || r.waiting !== 1) throw new Error(`report says ${JSON.stringify(r)}`);
  });
  h.eq('suspend needs a reason', await err(`select staff_suspend_bot($1, 'bad')`, [live]), 'Give a reason (at least 5 characters)');
  h.eq('cannot suspend own bot', await err(`select staff_suspend_bot($1, 'spamming people')`, [ownBot]), 'You can\'t suspend your own bot');
  h.eq('cannot suspend an admin bot', await err(`select staff_suspend_bot($1, 'spamming people')`, [adminBot]), 'That bot belongs to an admin');
  await h.ok('dev manager suspends a bot', () => h.q(`select staff_suspend_bot($1, 'spamming people in DMs')`, [live]));
  h.eq('suspending twice: not live', await err(`select staff_suspend_bot($1, 'spamming people in DMs')`, [live]), 'That bot isn\'t listed or verified');
  await h.admin();
  h.eq('suspended: unlisted, unverified, note', await h.one(`select public, unlisted, verified_at is null gone, review_note from bots where id = $1`, [live]),
    { public: false, unlisted: false, gone: true, review_note: 'Suspended: spamming people in DMs' });
  h.eq('its promotion ended', (await h.one(`select ends_at <= now() done, ended_by from bot_promotions where id = $1`, [promo])), { done: true, ended_by: dev });
  h.eq('suspension logged', (await h.one(`select count(*)::int n from mod_log where action = 'bot_suspended' and actor = $1`, [dev])).n, 1);
  await h.q(`insert into mod_log (actor, action, target_id) select $1, 'bot_suspended', $2 from generate_series(1, 9)`, [dev, live]);
  await h.q(`update bots set public = true where id = $1`, [live]);
  await h.as(dev);
  h.eq('10 suspensions an hour', await err(`select staff_suspend_bot($1, 'spamming people again')`, [live]), 'That\'s 10 bot suspensions this hour. Wait a bit or ask an admin');
  await h.as(mod);
  h.eq('plain mod cannot suspend', await err(`select staff_suspend_bot($1, 'spamming people')`, [live]), 'Admins only');
  await h.as(admin);
  await h.ok('admin suspends without the cap', () => h.q(`select staff_suspend_bot($1, 'spamming people again')`, [live]));
  await h.ok('admin reads both reports', () => h.q(`select staff_deco_sales(7), staff_dev_report()`));

  // Mods and plain users: unchanged.
  await h.as(mod);
  await h.ok('mod still reviews decos', () => h.q(`select review_community_deco($1, 'rejected', 'blurry')`, [more]));
  await h.ok('mod still reviews bots', () => h.q(`select admin_verify_bot($1, false, 'needs work')`, [ownBot]));
  h.eq('mod cannot read the sale report', await err(`select staff_deco_sales()`), 'Admins only');
  h.eq('mod sees area managers', (await h.one(`select count(*)::int n from site_area_managers`)).n, 2);
  await h.as(u);
  h.eq('plain user sees no area managers', (await h.one(`select count(*)::int n from site_area_managers`)).n, 0);
  await h.fails('plain user cannot write area managers', `insert into site_area_managers (user_id, area) values ($1, 'art')`, [u]);
  await h.fails('plain user cannot call area_manager_may', `select area_manager_may('badge')`);
  await h.as(null);
  await h.fails('anon cannot ask my_areas', `select my_areas()`);

  // Taking it off: badge gone, logged; a banned manager sleeps.
  await h.as(admin);
  await h.ok('admin takes Art Manager off', () => h.q(`select admin_set_area_manager($1, 'art', false, 'done')`, [art]));
  await h.admin();
  h.eq('badge gone', (await badges(art)).includes('art_manager'), false);
  h.eq('removal logged', (await h.one(`select count(*)::int n from mod_log where action = 'art_manager_removed'`)).n, 1);
  h.eq('no longer an art manager', await areas(art), []);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'test')`, [dev]);
  h.eq('banned dev manager sleeps', await areas(dev), []);
  await h.admin();
  await h.q(`insert into site_area_managers (user_id, area) values ($1, 'art')`, [mod]);
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'area_managers'`, [mod]);
  h.eq('mod with a role: art', await areas(mod), ['art']);
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [mod]);
  h.eq('paused mod: role sleeps too', await areas(mod), []);
  await h.as(admin);
  h.eq('banned accounts cannot be given a role', await err(`select admin_set_area_manager($1, 'art', true)`, [dev]), 'That account is banned');
}
