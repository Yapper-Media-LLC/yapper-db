// 297: private verified bots (bots.unlisted, flag private_verify). Existing bots behave exactly as before (nothing is
// backfilled, the legacy "private but verified, no badge" bot keeps its state); an unlisted bot waits in the same
// review queue, gets the checkmark when approved and loses it when rejected, withdrawn or published (publishing is a
// fresh public review); anyone with its ID can add a verified unlisted bot, nobody can add an unreviewed one; and it
// never shows up in public_bots().
// PGlite can't replay every migration, so: 001..024, flags (031, 041), stand-ins for the live bot pieces (the bots
// table with its live columns, 117's submit trigger, 160's grants), the live definitions 297 changes (copied verbatim
// from the live database, read-only, Oct 19) and 185 (the badge triggers + public_bots), then 297 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists verified_as text;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists muted_reason text;
alter table public.profiles add column if not exists voice_muted_until timestamptz;
alter table public.profiles add column if not exists stripe_customer text;
alter table public.profiles add column if not exists server_tag uuid;
alter table public.profiles add column if not exists tag text;
alter table public.profiles add column if not exists discriminator text;
revoke update (id, created_at, badges, plus_until, verified_as, muted_until, muted_reason, voice_muted_until, stripe_customer)
  on public.profiles from authenticated, anon;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz, suspended_reason text);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid,
  message_id uuid, reason text, created_at timestamptz not null default now());
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
end $$;

-- bots with its live columns (103 + 109 + 117 + 121 + 127 + 133).
create table if not exists public.bots (
  id uuid primary key references public.profiles(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null, description text not null default '', token_hash text, token_prefix text,
  webhook_url text, webhook_secret text, public boolean not null default false,
  created_at timestamptz not null default now(), last_used_at timestamptz, posts bigint not null default 0,
  last_poll_at timestamptz, last_event_at timestamptz, submitted_at timestamptz, verified_at timestamptz,
  review_note text, presence jsonb, category text default 'other', avatar_path text, tag text
);
alter table public.bots enable row level security;
create policy "bots visible" on public.bots for select to authenticated using (owner_id = auth.uid() or public);
create table if not exists public.bot_servers (
  bot_id uuid not null references public.bots(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  added_by uuid, added_at timestamptz not null default now(),
  primary key (bot_id, server_id)
);
alter table public.bot_servers enable row level security;
-- 160
revoke all on public.bots from anon, authenticated;
grant select (id, owner_id, name, tag, description, category, public, avatar_path, presence, posts,
              created_at, last_used_at, last_poll_at, last_event_at, submitted_at, verified_at, review_note)
  on public.bots to authenticated;
-- 117
create or replace function public.bot_public_submit() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.public and not coalesce(old.public, false) then
    new.submitted_at := now();
    new.verified_at := null;
    new.review_note := null;
  elsif not new.public then
    new.verified_at := null;
  end if;
  return new;
end $$;
create or replace trigger bots_public_submit before update of public on public.bots for each row execute function public.bot_public_submit();
-- 047: vanity-style invite codes.
alter table public.invites drop constraint if exists invites_code_check;
alter table public.invites add constraint invites_code_check check (code ~ '^[A-Za-z0-9_-]{3,32}$');
alter table public.invites add column if not exists vanity boolean not null default false;
insert into public.feature_flags (key, label, description, mode) values ('bot_api', 'Bot API', 'Bots', 'everyone') on conflict (key) do update set mode = 'everyone';
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
const LIVE = `
CREATE OR REPLACE FUNCTION public.admin_set_badge(uid uuid, badge text, on_off boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (public.is_site_admin() or (public.is_site_mod() and badge = 'bug_hunter')) then raise exception 'Admins only'; end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff') then raise exception 'Unknown badge'; end if;
  perform public.mod_guard('badge', uid, null);
  update public.profiles set badges = case when on_off then array(select distinct unnest(badges || badge)) else array_remove(badges, badge) end where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;

CREATE OR REPLACE FUNCTION public.admin_verify_bot(bid uuid, ok boolean, note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if ok then
    update public.bots set verified_at = now(), review_note = null where id = bid;
  else
    update public.bots set public = false, verified_at = null, review_note = left(coalesce(note, 'Not approved'), 300) where id = bid;
  end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), case when ok then 'bot_verified' else 'bot_rejected' end, bid,
            left(coalesce(nullif(btrim(note), ''), case when ok then 'Approved' else 'Not approved' end) || ' [' || coalesce((select name from public.bots where id = bid), 'bot') || ']', 500));
end $function$;

CREATE OR REPLACE FUNCTION public.bot_add_to_server(bid uuid, sid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.feature_on('bot_api', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can add bots'; end if;
  if not exists (select 1 from public.bots b where b.id = bid and (b.owner_id = auth.uid() or (b.public and b.verified_at is not null))) then
    raise exception 'That bot isn''t available (community bots must be verified by Yapper first)';
  end if;
  if (select count(*) from public.bot_servers where server_id = sid) >= 25 then raise exception 'That server has enough bots already'; end if;
  insert into public.bot_servers (bot_id, server_id, added_by) values (bid, sid, auth.uid()) on conflict do nothing;
  perform set_config('yapper.bot', '1', true);
  insert into public.server_members (server_id, user_id) values (sid, bid) on conflict do nothing;
  perform set_config('yapper.bot', '', true);
end $function$;

CREATE OR REPLACE FUNCTION public.feature_on_for_me(k text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (auth.uid() = any(users) or exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers)))) from public.feature_flags where key = k), false);
$function$;

CREATE OR REPLACE FUNCTION public.feature_on(k text, sid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false);
$function$;

CREATE OR REPLACE FUNCTION public.protect_profile_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if current_user = 'authenticated' and not public.is_site_admin() then
    new.id := old.id; new.created_at := old.created_at; new.verified_as := old.verified_as; new.plus_until := old.plus_until;
    new.muted_until := old.muted_until; new.muted_reason := old.muted_reason; new.voice_muted_until := old.voice_muted_until;
    new.stripe_customer := old.stripe_customer; new.badges := old.badges;
    new.server_tag := old.server_tag; new.tag := old.tag; new.discriminator := old.discriminator;
  end if;
  return new;
end; $function$;
drop trigger if exists profiles_0_protect on public.profiles;
create trigger profiles_0_protect before update on public.profiles for each row execute function public.protect_profile_columns();
`;

/** Live too (read-only, Oct 19): the review queue, which 297 re-creates with one more column, and bot_commands for its count. */
const LIVE2 = `
create table if not exists public.bot_commands (id uuid primary key default gen_random_uuid(), bot_id uuid not null references public.bots(id) on delete cascade, name text not null default 'cmd', description text);
CREATE OR REPLACE FUNCTION public.bot_review_queue()
 RETURNS TABLE(id uuid, name text, description text, owner_id uuid, owner_name text, owner_plus boolean, submitted_at timestamp with time zone, servers bigint, posts bigint, commands bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select b.id, b.name, b.description, b.owner_id, p.username, coalesce(p.plus_until > now(), false), b.submitted_at,
         (select count(*) from public.bot_servers s where s.bot_id = b.id), b.posts,
         (select count(*) from public.bot_commands c where c.bot_id = b.id)
  from public.bots b join public.profiles p on p.id = b.owner_id
  where b.public and b.verified_at is null and public.is_site_admin()
  order by coalesce(p.plus_until > now(), false) desc, b.submitted_at nulls last;
$function$;
grant execute on function public.bot_review_queue() to authenticated;
`;

export default async function (h) {
  const read = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
  const M185 = read('185_bot_verified.sql');
  const M297 = read('297_private_verify.sql');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(LIVE2);

  const adm = await h.signup('adm@test.dev', 'adm');
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const mk = async (name) => (await h.signup(`${name}@test.dev`, name));
  const yop = await mk('yop');       // the legacy bot: private, verified, no badge
  const pubb = await mk('pubbot');   // an ordinary public verified bot
  const pv = await mk('pvbot');      // asks for private verification
  const rj = await mk('rjbot');      // gets rejected
  const pub2 = await mk('pubtwo');   // public verified, goes private keeping the checkmark
  const pend = await mk('pendbot');  // an ordinary pending public bot
  const leg = await mk('legbot');    // another legacy private + verified bot, whose owner will ask for private verification
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [adm]);
  await h.q(`update profiles set badges = '{bot}' where id in ($1, $2, $3, $4, $5, $6, $7)`, [yop, pubb, pv, rj, pub2, pend, leg]);
  // The state before 297: yop is verified but private (nothing clears it since 117 only runs on UPDATE OF public).
  await h.q(`insert into bots (id, owner_id, name, description, public, verified_at) values ($1, $2, 'yop', 'Private helper for one server', false, now() - interval '20 days')`, [yop, amy]);
  await h.q(`insert into bots (id, owner_id, name, description, public, verified_at) values ($1, $2, 'legbot', 'Old private helper, was approved long ago', false, now() - interval '40 days')`, [leg, amy]);
  await h.db.exec(M185);
  await h.q(`insert into bots (id, owner_id, name, description, public, verified_at, category, tag) values ($1, $2, 'pubbot', 'Public and verified, lists on /bots', true, now() - interval '10 days', 'fun', '1111')`, [pubb, amy]);
  await h.q(`insert into bots (id, owner_id, name, description, public, verified_at, category, tag) values ($1, $2, 'pubtwo', 'Public and verified too, soon private', true, now() - interval '5 days', 'fun', '2222')`, [pub2, amy]);
  await h.q(`insert into bots (id, owner_id, name, description, public, submitted_at) values ($1, $2, 'pendbot', 'Waiting for the public review', true, now())`, [pend, amy]);
  await h.q(`insert into bots (id, owner_id, name, description) values ($1, $2, 'pvbot', 'Runs the weekly tournament for our server only'), ($3, $2, 'rjbot', 'A short one')`, [pv, amy, rj]);
  await h.q(`update feature_flags set mode = 'everyone' where key in ('bot_verified', 'bot_api')`);

  const badges = async (id) => { await h.admin(); return (await h.one(`select badges from profiles where id = $1`, [id])).badges; };
  const st = async (id) => { await h.admin(); const r = await h.one(`select public, unlisted, verified_at is not null as verified, submitted_at is not null as submitted, review_note from bots where id = $1`, [id]); return r; };
  const listed = async (who) => { await h.as(who); return (await h.q(`select name from public_bots()`)).map((r) => r.name).sort(); };
  const queue = async (who) => { await h.as(who); return (await h.q(`select name, unlisted from bot_review_queue() order by name`)).map((r) => [r.name, r.unlisted]); };

  // ---- before: yop has no badge, the public verified bot has one ----
  h.eq('before: legacy private verified bot has no badge', await badges(yop), ['bot']);
  h.eq('before: public verified bot has it', await badges(pubb), ['bot', 'verified_bot']);

  await h.db.exec(M297);
  await h.ok('297 re-runs cleanly', () => h.db.exec(M297));

  // ---- column + flag ----
  h.eq('flag row: test mode, test server + Antic', await h.one(`select mode, servers, users from feature_flags where key = 'private_verify'`),
    { mode: 'test', servers: ['00000000-0000-4000-8000-00000000b001'], users: ['00000000-0000-4000-8000-00000000a001'] });
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'private_verify'`);
  await h.db.exec(M297);
  h.eq('re-running never moves a flag Antic changed', (await h.one(`select mode from feature_flags where key = 'private_verify'`)).mode, 'off');
  h.eq('nothing is unlisted yet', (await h.one(`select count(*)::int n from bots where unlisted`)).n, 0);
  h.eq('legacy bot: untouched, still verified, still no badge', [await st(yop), await badges(yop)],
    [{ public: false, unlisted: false, verified: true, submitted: false, review_note: null }, ['bot']]);
  h.eq('public verified bot: untouched, badge kept', [(await st(pubb)).verified, await badges(pubb)], [true, ['bot', 'verified_bot']]);
  await h.as(amy);
  h.eq('owner can read unlisted', (await h.one(`select unlisted from bots where id = $1`, [pv])).unlisted, false);
  await h.fails('clients can not set unlisted themselves', `update bots set unlisted = true where id = $1`, [pv]);
  await h.fails('nor verified_at', `update bots set verified_at = now() where id = $1`, [pv]);

  // ---- ask for private verification (what PATCH /api/bots does, with the service role) ----
  await h.admin();
  await h.q(`update bots set unlisted = true, public = false, submitted_at = now(), review_note = null where id = $1`, [pv]);
  h.eq('requested: private, waiting, no badge', [await st(pv), await badges(pv)],
    [{ public: false, unlisted: true, verified: false, submitted: true, review_note: null }, ['bot']]);
  h.eq('admin queue: the private request, flagged, next to the ordinary public one', await queue(adm), [['pendbot', false], ['pvbot', true]]);
  h.eq('queue: nothing for anyone else', [(await queue(bob)).length, (await queue(amy)).length], [0, 0]);
  await h.as(null);
  await h.fails('queue: logged out is refused', `select * from bot_review_queue()`);
  h.eq('not on /bots while waiting', await listed(null), ['pubbot', 'pubtwo']);

  // Adding: its owner can (always could), nobody else until it is verified.
  await h.as(amy);
  const amys = (await h.one(`select create_server('Amys', null) id`)).id;
  await h.ok('owner adds their own unreviewed bot', () => h.q(`select bot_add_to_server($1, $2)`, [pv, amys]));
  await h.as(bob);
  const bobs = (await h.one(`select create_server('Bobs', null) id`)).id;
  await h.fails('someone else can not add it before it is verified', `select bot_add_to_server($1, $2)`, [pv, bobs]);
  await h.fails('nor the legacy private bot', `select bot_add_to_server($1, $2)`, [yop, bobs]);

  // ---- approve ----
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true, 'Looks fine')`, [pv]);
  h.eq('approved: verified, still private, has the checkmark', [await st(pv), await badges(pv)],
    [{ public: false, unlisted: true, verified: true, submitted: true, review_note: null }, ['bot', 'verified_bot']]);
  h.eq('mod log says it was a private one', (await h.one(`select action, reason from mod_log where target_id = $1 order by created_at desc limit 1`, [pv])),
    { action: 'bot_verified', reason: 'Looks fine (private) [pvbot]' });
  h.eq('queue: only the ordinary one is left', await queue(adm), [['pendbot', false]]);
  h.eq('still not on /bots (anon)', await listed(null), ['pubbot', 'pubtwo']);
  h.eq('nor for a signed-in user', await listed(bob), ['pubbot', 'pubtwo']);
  await h.as(bob);
  await h.ok('anyone with the ID adds it now', () => h.q(`select bot_add_to_server($1, $2)`, [pv, bobs]));
  await h.admin();
  h.eq('it joined as a member and in bot_servers', (await h.one(`select (select count(*)::int from bot_servers where bot_id = $1 and server_id = $2) a, (select count(*)::int from server_members where user_id = $1 and server_id = $2) m`, [pv, bobs])), { a: 1, m: 1 });
  await h.as(bob);
  await h.fails('the legacy bot is still closed to others', `select bot_add_to_server($1, $2)`, [yop, bobs]);
  await h.fails('a pending public bot is still closed to others', `select bot_add_to_server($1, $2)`, [pend, bobs]);
  await h.admin();
  await h.q(`update bots set posts = posts + 1, last_used_at = now() where id = $1`, [pv]);
  h.eq('other updates leave the checkmark', await badges(pv), ['bot', 'verified_bot']);

  // ---- remove verification ----
  await h.q(`update bots set unlisted = false, verified_at = null where id = $1`, [pv]); // PATCH unlisted:false
  h.eq('removed: no badge, plain private bot again', [await st(pv), await badges(pv)],
    [{ public: false, unlisted: false, verified: false, submitted: true, review_note: null }, ['bot']]);
  h.eq('it stays in the servers it joined', (await h.one(`select count(*)::int n from bot_servers where bot_id = $1`, [pv])).n, 2);
  await h.as(adm);
  h.eq('and is not in the queue', await queue(adm), [['pendbot', false]]);

  // ---- publishing a private verified bot is a fresh public review ----
  await h.admin();
  await h.q(`update bots set unlisted = true, submitted_at = now() where id = $1`, [pv]);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true)`, [pv]);
  h.eq('verified privately again', await badges(pv), ['bot', 'verified_bot']);
  await h.admin();
  await h.q(`update bots set public = true where id = $1`, [pv]); // owner publishes
  h.eq('published: back in review as a public bot, checkmark paused', [await st(pv), await badges(pv)],
    [{ public: true, unlisted: false, verified: false, submitted: true, review_note: null }, ['bot']]);
  h.eq('queue shows it as an ordinary public one', await queue(adm), [['pendbot', false], ['pvbot', false]]);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true)`, [pv]);
  h.eq('approved publicly: listed with the checkmark', [await listed(null), await badges(pv)], [['pubbot', 'pubtwo', 'pvbot'], ['bot', 'verified_bot']]);
  h.eq('public approval has no (private) in the log', (await h.one(`select reason from mod_log where target_id = $1 order by created_at desc limit 1`, [pv])).reason, 'Approved [pvbot]');

  // ---- reject ----
  await h.admin();
  await h.q(`update bots set unlisted = true, public = false, submitted_at = now() where id = $1`, [rj]);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, false, 'Add a real description')`, [rj]);
  h.eq('rejected: back to a plain private bot with the note', [await st(rj), await badges(rj)],
    [{ public: false, unlisted: false, verified: false, submitted: true, review_note: 'Add a real description' }, ['bot']]);
  h.eq('mod log marks the private one', (await h.one(`select action, reason from mod_log where target_id = $1 order by created_at desc limit 1`, [rj])),
    { action: 'bot_rejected', reason: 'Add a real description (private) [rjbot]' });
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, false, 'Not yet')`, [pend]);
  h.eq('rejecting an ordinary public one is unchanged', [await st(pend), (await h.one(`select reason from mod_log where target_id = $1 order by created_at desc limit 1`, [pend])).reason],
    [{ public: false, unlisted: false, verified: false, submitted: true, review_note: 'Not yet' }, 'Not yet [pendbot]']);
  await h.as(bob);
  await h.fails('only admins review', `select admin_verify_bot($1, true)`, [rj]);

  // ---- a public verified bot can go private and keep the checkmark ----
  await h.admin();
  await h.q(`update bots set public = false, unlisted = true where id = $1`, [pub2]); // PATCH unlisted:true on a public verified bot
  h.eq('went private with the checkmark', [await st(pub2), await badges(pub2)],
    [{ public: false, unlisted: true, verified: true, submitted: false, review_note: null }, ['bot', 'verified_bot']]);
  h.eq('and left /bots', await listed(null), ['pubbot', 'pvbot']);
  await h.admin();
  await h.q(`update bots set public = false where id = $1`, [pub2]);
  h.eq('a repeated private update keeps it', (await st(pub2)).verified, true);
  // Today's behaviour for everyone else is unchanged: going private clears verification.
  await h.q(`update bots set public = false where id = $1`, [pubb]);
  h.eq('plain public -> private still clears verification and the badge', [await st(pubb), await badges(pubb)],
    [{ public: false, unlisted: false, verified: false, submitted: false, review_note: null }, ['bot']]);
  h.eq('and the unlisted bot is still not listed', await listed(null), ['pvbot']);

  // ---- insert / delete ----
  const gone = await mk('gonebot');
  await h.admin();
  await h.q(`insert into bots (id, owner_id, name, unlisted, verified_at) values ($1, $2, 'gonebot', true, now())`, [gone, amy]);
  h.eq('inserted as private + verified: badge', await badges(gone), ['verified_bot']);
  await h.q(`delete from bots where id = $1`, [gone]);
  h.eq('row deleted: badge gone', await badges(gone), []);

  // ---- a legacy private + verified bot that asks for private verification is reviewed like any other ----
  await h.admin();
  h.eq('legacy bot before: verified, no badge', [(await st(leg)).verified, await badges(leg)], [true, ['bot']]);
  await h.q(`update bots set unlisted = true, public = false, submitted_at = now(), review_note = null where id = $1`, [leg]); // what PATCH sends
  h.eq('asked: its old verified_at is cleared, it waits, no badge', [await st(leg), await badges(leg)],
    [{ public: false, unlisted: true, verified: false, submitted: true, review_note: null }, ['bot']]);
  h.eq('and shows in the queue as private', (await queue(adm)).filter((r) => r[0] === 'legbot'), [['legbot', true]]);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true, null, true)`, [leg]);
  h.eq('approved: now it has the checkmark', await badges(leg), ['bot', 'verified_bot']);

  // ---- a single-column update can't leave perks behind without the badge ----
  await h.admin();
  await h.q(`update bots set unlisted = false where id = $1`, [leg]); // nothing else in the SET list
  h.eq('unlisted -> false alone: verification and badge both go', [await st(leg), await badges(leg)],
    [{ public: false, unlisted: false, verified: false, submitted: true, review_note: null }, ['bot']]);

  // ---- stale queue rows ----
  await h.q(`update bots set unlisted = true, public = false, submitted_at = now() where id = $1`, [leg]);
  await h.q(`update bots set unlisted = false where id = $1`, [leg]); // the maker cancels
  await h.as(adm);
  await h.fails('approving a cancelled request is refused', `select admin_verify_bot($1, true, null, true)`, [leg]);
  await h.fails('so is sending it back', `select admin_verify_bot($1, false, 'no', true)`, [leg]);
  h.eq('nothing changed by the refused calls', [await st(leg), await badges(leg)],
    [{ public: false, unlisted: false, verified: false, submitted: true, review_note: null }, ['bot']]);
  await h.admin();
  await h.q(`update bots set unlisted = true, public = false, submitted_at = now() where id = $1`, [leg]);
  await h.q(`update bots set public = true where id = $1`, [leg]); // the maker publishes instead
  await h.as(adm);
  await h.fails('approving a private row that became public is refused', `select admin_verify_bot($1, true, null, true)`, [leg]);
  await h.ok('the same bot approved as public (the admin looked at it as public)', () => h.q(`select admin_verify_bot($1, true, null, false)`, [leg]));
  h.eq('listed now, and the log has no (private)', [await listed(null), (await h.one(`select reason from mod_log where target_id = $1 order by created_at desc limit 1`, [leg])).reason],
    [['legbot', 'pvbot'], 'Approved [legbot]']);
  await h.admin();
  await h.q(`update bots set public = false, unlisted = true where id = $1`, [leg]); // verified public -> private, keeps the check
  await h.as(adm);
  await h.fails('a public row that became private is refused too', `select admin_verify_bot($1, true, null, false)`, [leg]);
  await h.ok('an older caller that does not send was_private still works', () => h.q(`select admin_verify_bot($1, true, 'fine')`, [leg]));
  await h.fails('a bot that is neither public nor unlisted can not be approved', `select admin_verify_bot($1, true)`, [yop]);
  h.eq('one admin_verify_bot only (no ambiguous overload)', (await h.one(`select count(*)::int n from pg_proc where proname = 'admin_verify_bot'`)).n, 1);
  h.eq('anon can not run it', (await h.one(`select has_function_privilege('anon', 'public.admin_verify_bot(uuid, boolean, text, boolean)', 'execute') a, has_function_privilege('authenticated', 'public.admin_verify_bot(uuid, boolean, text, boolean)', 'execute') b`)),
    { a: false, b: true });

  // ---- the trigger function stays private ----
  await h.as(bob);
  await h.fails('the badge trigger function is not callable', `select bot_verified_badge()`);
  try { await h.q(`update profiles set badges = badges || 'verified_bot'::text where id = $1`, [pend]); } catch { /* refused: fine */ }
  h.eq('nobody gives the badge by hand', await badges(pend), ['bot']);
  await h.as(bob);
  h.eq('queue grant: signed in only', (await h.one(`select has_function_privilege('anon', 'public.bot_review_queue()', 'execute') a, has_function_privilege('authenticated', 'public.bot_review_queue()', 'execute') b`)),
    { a: false, b: true });
  await h.as(null);
}
